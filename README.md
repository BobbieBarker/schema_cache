# SchemaCache

[![Hex.pm](https://img.shields.io/hexpm/v/schema_cache.svg)](https://hex.pm/packages/schema_cache)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/schema_cache)
[![CI](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/BobbieBarker/schema_cache/branch/main/graph/badge.svg)](https://codecov.io/gh/BobbieBarker/schema_cache)

An Ecto-aware caching library implementing **Read Through**, **Write Through**,
and **Schema Mutation Key Eviction Strategy (SMKES)**.

SchemaCache understands the relationship between your Ecto schemas and cached
query results. When a schema is mutated, it knows exactly which cached values
are affected and can evict or update them automatically, requiring no manual
cache invalidation.

## Installation

Add `schema_cache` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schema_cache, "~> 0.1.0"}
  ]
end
```

Then configure your cache adapter:

```elixir
# config/config.exs
config :schema_cache, adapter: SchemaCache.Adapters.ETS
```

Add `SchemaCache.Supervisor` to your application supervision tree:

```elixir
children = [
  {SchemaCache.Supervisor, adapter: SchemaCache.Adapters.ETS},
  # ... other children
]
```

## Quick Start

SchemaCache provides four core operations: **read**, **create**, **update**,
and **delete**.

### Read Through

On a cache miss, SchemaCache invokes your callback to fetch from the source,
caches the result, and records which schemas appear in it for later eviction.

```elixir
# Cache a single record
{:ok, user} =
  SchemaCache.read("find_user", %{id: 5}, :timer.minutes(15), fn ->
    MyApp.Users.find(%{id: 5})
  end)

# Cache a collection (prefix with "all_" for write-through support)
users =
  SchemaCache.read("all_active_users", %{active: true}, :timer.minutes(5), fn ->
    MyApp.Users.all(%{active: true})
  end)
```

### Create

After inserting a new record, evict all cached collections for that schema
type so they refresh on the next read and include the new record.

```elixir
{:ok, new_user} =
  SchemaCache.create(fn ->
    %User{}
    |> User.changeset(%{name: "Bob", email: "bob@example.com"})
    |> Repo.insert()
  end)
```

### Update with Eviction (default)

After an update, evict all cache keys that reference the mutated schema
instance. The next read will fetch fresh data from the source.

```elixir
{:ok, updated_user} =
  SchemaCache.update(fn ->
    MyApp.Users.update_user(user, %{name: "Alice"})
  end)
```

### Update with Write Through

Update all cached values referencing the schema in place, avoiding cache misses
entirely. Ideal for updates where you want zero-latency reads after the write.

```elixir
{:ok, updated_user} =
  SchemaCache.update(
    fn -> MyApp.Users.update_user(user, %{name: "Alice"}) end,
    strategy: :write_through
  )
```

### Delete

After a deletion, evict all cache keys that reference the deleted schema
instance.

```elixir
{:ok, deleted_user} =
  SchemaCache.delete(fn -> Repo.delete(user) end)
```

## How SMKES Works

Schema Mutation Key Eviction Strategy (SMKES) is the core innovation of this
library. It maintains a reverse index from Ecto schemas to every cache key
where they appear. When a schema is mutated, SchemaCache looks up the reverse
index and takes action on every affected cache entry.

### Key Reference Tracking

When a query result is cached via `read/4`, SchemaCache inspects the result to
find Ecto structs and records two types of references:

1. **Instance references**: maps a specific schema instance (e.g. `User#5`)
   to every cache key containing it.
2. **Type references**: maps a schema module (e.g. `User`) to every cache key
   holding a collection of that type. Used by `create/1` to evict collections
   that need to include the newly created record.

References are stored as compact integer IDs via `SchemaCache.KeyRegistry`,
reducing memory usage by approximately 10x compared to storing full cache key
strings.

```
                         SMKES: Key Reference Tracking
  =========================================================================

  SchemaCache.read("find_user", %{id: 5}, ttl, fn -> ... end)
  SchemaCache.read("all_users", %{active: true}, ttl, fn -> ... end)

                  Cache Storage                     Key Reference Sets
              +------------------+             +-------------------------+
              | find_user:{...}  |             | User#5                  |
              |   => %User{id:5} |      .----->|   => [1, 2]            |
              +------------------+     /       |   (integer IDs from     |
                        |             /        |    KeyRegistry)         |
          cache_key ----+--- sadd ---'         +-------------------------+
                                               +-------------------------+
              +------------------+      .----->| User#8                  |
              | all_users:{...}  |     /       |   => [2]               |
              |   => [%User{id:5}|    /        +-------------------------+
              |       %User{id:8}|---'         +-------------------------+
              |      ]           |- - sadd - ->| User (type)             |
              +------------------+             |   => [2]               |
                                               +-------------------------+
```

### Read Through Flow

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

### Write Through Flow

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

### Eviction Flow (default and create)

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
  schema module name (e.g. "User") instead of the instance
  identity (e.g. "User#5"), evicting all collections of
  that type.
```

## Adapter Configuration

SchemaCache is adapter-agnostic. Any module implementing the
`SchemaCache.Adapter` behaviour can be used as a backend.

### Built-in: ETS Adapter

A simple single-node adapter backed by ETS. Does not support TTL.
Suitable for development, testing, and single-node deployments.

```elixir
config :schema_cache, adapter: SchemaCache.Adapters.ETS
```

### Custom Adapters

Implement the `SchemaCache.Adapter` behaviour with three required callbacks:
`get/1`, `put/3`, and `delete/1`. SchemaCache builds its key reference
tracking on top of these primitives, so your adapter only needs basic
key-value operations.

Adapters can optionally implement `sadd/2`, `srem/2`, `smembers/1`, and
`mget/1` for native set operations and batch reads. Adapters without these
callbacks automatically fall back to a partitioned lock mechanism via
`SchemaCache.SetLock`.

```elixir
defmodule MyApp.SchemaCacheAdapter do
  @behaviour SchemaCache.Adapter

  @impl true
  def get(key) do
    case MyApp.Cache.get(key) do
      nil -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  @impl true
  def put(key, value, opts) do
    ttl = Keyword.get(opts, :ttl)
    MyApp.Cache.put(key, value, ttl: ttl)
    :ok
  end

  @impl true
  def delete(key) do
    MyApp.Cache.delete(key)
    :ok
  end
end
```

Then configure it:

```elixir
config :schema_cache, adapter: MyApp.SchemaCacheAdapter
```

## Key Conventions

When caching collections, prefix the key with `all_`. This convention is
required for write-through to correctly identify and update collections in
the cache versus singular values.

```elixir
# Singular, no prefix
SchemaCache.read("find_user", %{id: 5}, ttl, fn -> ... end)

# Collection, "all_" prefix
SchemaCache.read("all_users", %{active: true}, ttl, fn -> ... end)
```

## API Reference

Full API documentation is available on [HexDocs](https://hexdocs.pm/schema_cache).

## License

MIT License. See [LICENSE](LICENSE) for details.
