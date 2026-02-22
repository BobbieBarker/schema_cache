# How to Write a Custom Adapter

SchemaCache is adapter-agnostic. Any module implementing the `SchemaCache.Adapter` behaviour can serve as the cache backend.

## Required Callbacks

Every adapter must implement three callbacks:

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

### Return Conventions

- `get/1`: `{:ok, value}` on hit, `{:ok, nil}` on miss, `{:error, reason}` on failure.
- `put/3`: `:ok` or `{:error, reason}`.
- `delete/1`: `:ok` or `{:error, reason}`.

### TTL Handling

TTL is passed as `:ttl` in the `opts` keyword list of `put/3`. If your backend supports TTL, extract it with `Keyword.get(opts, :ttl)` and use it. If not, ignore it. SchemaCache does not implement its own TTL mechanism.

## Optional Callbacks

### `init/0`

Called by `SchemaCache.Supervisor` during startup. Use it to create ETS tables, open connections, or perform other initialization.

```elixir
@impl true
def init do
  :ets.new(:my_cache_table, [:set, :public, :named_table])
  :ok
end
```

### Native Set Operations

Implementing `sadd/2`, `srem/2`, and `smembers/1` lets your adapter handle SMKES reference sets natively instead of falling back to the partitioned lock mechanism in `SchemaCache.SetLock`.

This is especially valuable for backends like Redis that have built-in set operations:

```elixir
@impl true
def sadd(key, member) do
  case Redix.command(:redis, ["SADD", key, to_string(member)]) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end

@impl true
def srem(key, member) do
  case Redix.command(:redis, ["SREM", key, to_string(member)]) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end

@impl true
def smembers(key) do
  case Redix.command(:redis, ["SMEMBERS", key]) do
    {:ok, []} -> {:ok, nil}
    {:ok, members} -> {:ok, Enum.map(members, &String.to_integer/1)}
    {:error, reason} -> {:error, reason}
  end
end
```

Members are always integer IDs from `SchemaCache.KeyRegistry`. Return `{:ok, nil}` for empty or non-existent sets.

### Batch Reads with `mget/1`

Implementing `mget/1` enables efficient batch reads during write-through operations:

```elixir
@impl true
def mget(keys) do
  case Redix.command(:redis, ["MGET" | keys]) do
    {:ok, values} ->
      {:ok, Enum.map(values, fn
        nil -> nil
        binary -> :erlang.binary_to_term(binary)
      end)}

    {:error, reason} ->
      {:error, reason}
  end
end
```

Without `mget/1`, SchemaCache falls back to sequential `get/1` calls.

## Configuration

Pass your adapter to `SchemaCache.Supervisor` in your supervision tree:

```elixir
children = [
  {SchemaCache.Supervisor, adapter: MyApp.SchemaCacheAdapter},
  # ... other children
]
```

## Capability Resolution

At startup, SchemaCache inspects which optional callbacks your adapter implements and stores the result in a persistent term. This determines routing at runtime:

- **With** `sadd/2`, `srem/2`, `smembers/1`: Set operations go directly to your adapter.
- **Without**: Set operations route through `SchemaCache.SetLock`.
- **With** `mget/1`: Batch reads use your implementation.
- **Without**: Falls back to sequential `get/1` calls.

No configuration is needed. Capability detection is automatic.
