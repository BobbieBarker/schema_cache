# Architecture: How SMKES Works

Schema Mutation Key Eviction Strategy (SMKES) is the core innovation of SchemaCache. It maintains a reverse index from Ecto schemas to every cache key where they appear. When a schema is mutated, SchemaCache looks up the reverse index and takes action on every affected cache entry.

## Key Reference Tracking

When a query result is cached via `read/4`, SchemaCache inspects the result to find Ecto structs and records two types of references:

1. **Instance references**: Maps a specific schema instance (e.g., `User#5`) to every cache key containing it.
2. **Type references**: Maps a schema module (e.g., `User`) to every cache key holding a collection of that type. Used by `create/1` to evict collections that need to include the newly created record.

References are stored as compact integer IDs via `SchemaCache.KeyRegistry`, reducing memory usage by approximately 10x compared to storing full cache key strings.

Given these two cached queries:

```elixir
SchemaCache.read("find_user", %{id: 5}, ttl, fn -> Repo.get(User, 5) end)
SchemaCache.read("all_users", %{active: true}, ttl, fn -> Repo.all(User) end)
```

SchemaCache stores the results and builds these reverse-index sets:

```
Cache Entries (adapter key-value store)
───────────────────────────────────────────────────────────
  Key                     ID    Value
  find_user:{id:5}        1     %User{id: 5, name: "Alice"}
  all_users:{active:true} 2     [%User{id: 5}, %User{id: 8}]

Reverse-Index Sets (adapter set store)
───────────────────────────────────────────────────────────
  Set Key       Members   What it means
  __set:User#5  [1, 2]    User#5 appears in cache entries 1 and 2
  __set:User#8  [2]       User#8 appears in cache entry 2
  __set:User    [2]       Entry 2 is a User collection (for create/1)
```

When User#5 is mutated, SchemaCache reads `__set:User#5`, resolves
IDs `[1, 2]` back to cache keys via KeyRegistry, and evicts or
updates both entries.

## Cache-Aside Flow

On a cache miss, SchemaCache invokes the callback, caches the result, and records schema references.

```
SchemaCache.read("find_user", %{id: 5}, ttl, fn -> Repo.get(User, 5) end)

    +--------+              +-----------+          +----------+
    | Caller |  -- 1 -->    |SchemaCache|  -- 2 -> | Adapter  |
    +--------+              +-----------+          +----------+
        ^                        |                      |
        |                        |  cache miss (nil)    |
        |                        | <------- 3 ---------|
        |                        |                      |
        |                        | -- 4 -> callback()  --> +------+
        |                        |                          |  DB  |
        |                        | <- 5 -- {:ok, user} <-- +------+
        |                        |                      |
        |                        | -- 6 -> put(key,     |
        |                        |          user, ttl)  |
        |                        |                      |
        |                        | -- 7 -> sadd(        |
        |                        |     "User#5",        |
        |                        |     key_id)          |
        |                        |                      |
        | <-- 8 -- {:ok, user}   |                      |
        |                        |                      |

Subsequent calls with the same key and params return
the cached value at step 3 without invoking the callback.
```

## Write-Through Flow

Write-through updates cached values in place, avoiding cache misses after mutations.

```
SchemaCache.update(fn -> update_user(user, params) end, strategy: :write_through)

    +--------+              +-----------+          +----------+
    | Caller |  -- 1 -->    |SchemaCache|          | Adapter  |
    +--------+              +-----------+          +----------+
        ^                        |                      |
        |                        | -- 2 -> callback()  --> +------+
        |                        |                          |  DB  |
        |                        | <- 3 -- {:ok, updated}  +------+
        |                        |                      |
        |                        | -- 4 -> smembers(    |
        |                        |     "User#5")        |
        |                        |                      |
        |                        | <- 5 -- [id1, id2]   |
        |                        |                      |
        |                        | -- 6 -> resolve IDs, |
        |                        |   for each key:      |
        |                        |   put(key, updated)  |
        |                        |                      |
        | <- 7 -- {:ok, updated} |                      |
        |                        |                      |

For collection keys (prefixed with "all_"), SchemaCache
finds the specific item within the list by primary key
and replaces it in place.
```

## Eviction Flow

Default update and create use eviction. Affected cache entries are deleted and the next read re-populates from the source.

```
SchemaCache.update(fn -> update_user(user, params) end)

    +--------+              +-----------+          +----------+
    | Caller |  -- 1 -->    |SchemaCache|          | Adapter  |
    +--------+              +-----------+          +----------+
        ^                        |                      |
        |                        | -- 2 -> callback()  --> +------+
        |                        |                          |  DB  |
        |                        | <- 3 -- {:ok, updated}  +------+
        |                        |                      |
        |                        | -- 4 -> smembers(    |
        |                        |     "User#5")        |
        |                        |                      |
        |                        | <- 5 -- [id1, id2]   |
        |                        |                      |
        |                        | -- 6 -> resolve IDs, |
        |                        |   for each key:      |
        |                        |   delete(key)        |
        |                        |   srem("User#5",id)  |
        |                        |                      |
        | <- 7 -- {:ok, updated} |                      |
        |                        |                      |

create/1 behaves similarly but looks up keys by the
schema module name (e.g., "User") instead of the instance
identity (e.g., "User#5"), evicting all collections of
that type.
```

## KeyRegistry: Compact ID Storage

`SchemaCache.KeyRegistry` maintains a bidirectional mapping between cache key strings and integer IDs. SMKES reference sets store these integer IDs instead of full strings.

A cache key like `"all_users:{\"active\":true,\"order_by\":{\"name\":\"asc\"}}"` consumes ~80 bytes per set reference; an integer ID consumes ~8 bytes.

The registry uses two ETS tables for O(1) lookups in both directions:

- `:schema_cache_key_to_id`: `{cache_key, id}`
- `:schema_cache_id_to_key`: `{id, cache_key}`

ID generation uses `:atomics` for lock-free monotonic assignment.

## SetLock: Partitioned Lock Fallback

Adapters that don't implement native set operations (`sadd/2`, `srem/2`, `smembers/1`) fall back to `SchemaCache.SetLock`. This module serializes read-modify-write cycles using a partitioned lock pool backed by `Registry`, storing sets as `MapSet` values in the adapter's key-value store.

The lock is partitioned by `System.schedulers_online/0 * 4` to reduce contention. Concurrent writes to different set keys rarely contend, while writes to the same key are serialized by hashing to the same partition.

Adapters with native set operations (e.g., Redis SADD/SREM/SMEMBERS) bypass SetLock entirely.

## Capability Resolution

At startup, `SchemaCache.Supervisor` resolves the adapter's capabilities by checking which optional callbacks are implemented. This result is stored in a persistent term for O(1) access at runtime.

The resolved capabilities determine routing for all adapter operations:

- **Native set operations** (`sadd/2`, `srem/2`, `smembers/1`): Route directly to the adapter.
- **ElixirCache Redis** (`command/1`): Route set operations and `mget` through raw Redis commands.
- **Neither**: Set operations fall back to `SchemaCache.SetLock`.
- **Native `mget/1`**: Batch reads use the adapter's implementation.
- **Without `mget/1`**: Falls back to sequential `get/1` calls.

### ElixirCache Auto-Detection

Modules created with `use Cache` from [ElixirCache](https://github.com/MikaAK/elixir_cache) are detected automatically via `function_exported?(adapter, :cache_adapter, 0)`. SchemaCache translates API signatures at the dispatch layer. ElixirCache uses positional TTL (`put(key, ttl, value)`) while SchemaCache's behaviour uses keyword opts (`put(key, value, ttl: ttl)`). This translation is invisible to callers.

For Redis-backed ElixirCache modules, SchemaCache further detects `command/1` and uses it for native set operations and batch reads, bypassing the SetLock fallback entirely.
