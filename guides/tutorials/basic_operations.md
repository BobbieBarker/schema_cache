# Basic Operations

SchemaCache provides four core operations: **read**, **create**, **update**, and **delete**. Each operation is Ecto-aware. SchemaCache inspects query results to find Ecto structs and automatically maintains a reverse index from schemas to cache keys.

## Cache-Aside

`read/4` checks the cache first. On a miss, it invokes your callback, caches the result, and records which schemas appear in it for later eviction.

### Caching a Single Record

```elixir
{:ok, user} =
  SchemaCache.read("find_user", %{id: 5}, :timer.minutes(15), fn ->
    MyApp.Users.find(%{id: 5})
  end)
```

The first call executes the callback and caches the result. Subsequent calls with the same key and params return the cached value directly.

### Caching a Collection

Prefix collection keys with `"all_"`. This convention is required for write-through to distinguish collections from singular values.

```elixir
{:ok, users} =
  SchemaCache.read("all_active_users", %{active: true}, :timer.minutes(5), fn ->
    {:ok, MyApp.Users.all(%{active: true})}
  end)
```

### How the Cache Key Works

The cache key is derived from the first two arguments: `key` and `params`. Params are deterministically serialized, so `%{a: 1, b: 2}` and `%{b: 2, a: 1}` produce the same cache key.

## Create

After inserting a new record, `create/1` evicts all cached collections for that schema type. This ensures the next read includes the new record.

```elixir
{:ok, new_user} =
  SchemaCache.create(fn ->
    %User{}
    |> User.changeset(%{name: "Bob", email: "bob@example.com"})
    |> Repo.insert()
  end)
```

On success, SchemaCache looks up all cache keys associated with the `User` schema type (collection references) and evicts them.

## Update

### Eviction (Default)

By default, `update/2` evicts all cache keys that reference the mutated schema instance. The next read will fetch fresh data.

```elixir
{:ok, updated_user} =
  SchemaCache.update(fn ->
    MyApp.Users.update_user(user, %{name: "Alice"})
  end)
```

### Write Through

With `:write_through`, SchemaCache updates cached values in place instead of evicting them. This avoids cache misses after writes.

```elixir
{:ok, updated_user} =
  SchemaCache.update(
    fn -> MyApp.Users.update_user(user, %{name: "Alice"}) end,
    strategy: :write_through
  )
```

Write-through handles both singular cached values and collections. For collections, SchemaCache finds the specific item by primary key and replaces it in the list.

## Delete

After a deletion, `delete/1` evicts all cache keys that reference the deleted schema instance.

```elixir
{:ok, deleted_user} =
  SchemaCache.delete(fn -> Repo.delete(user) end)
```

## Flush

`flush/2` evicts all cache entries associated with a specific schema instance. Use this when you need to invalidate cache entries for a schema outside of a create/update/delete flow.

```elixir
# Evict all cached queries that include User#5
SchemaCache.flush(user, :timer.minutes(15))
```

The TTL argument is passed to the adapter when re-storing reference sets (if applicable).

## Key Conventions

Cache keys are composed from two parts: a name and params map. The name determines the cache key prefix, and the params are deterministically serialized into the key.

### The `"all_"` Prefix

Keys prefixed with `"all_"` are treated as collection keys. This distinction matters for:

- **`create/1`**: Only evicts collection keys (prefixed with `"all_"`) for the schema type.
- **Write-through**: Updates items within lists for collection keys, replaces the entire value for singular keys.

```elixir
# Singular (no prefix)
SchemaCache.read("find_user", %{id: 5}, ttl, fn -> ... end)

# Collection ("all_" prefix required)
SchemaCache.read("all_users", %{active: true}, ttl, fn -> ... end)
```

### Params Determinism

Params maps are serialized deterministically using sorted keys and Jason encoding. This means `%{a: 1, b: 2}` and `%{b: 2, a: 1}` produce the same cache key.

## Next Steps

- Understand [how invalidation works](../explanation/architecture.md) under the hood.
- Learn how to [write a custom adapter](../how-to/writing_adapters.md).
- Integrate with [ElixirCache](../how-to/using_with_elixir_cache.md) for a production-ready backend.
