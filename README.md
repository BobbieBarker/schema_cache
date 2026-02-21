# SchemaCache

[![CI](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/schema_cache.svg)](https://hex.pm/packages/schema_cache)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An Ecto-aware caching library implementing **Read Through**, **Write Through**, and **Schema Mutation Key Eviction Strategy (SMKES)** for intelligent cache invalidation.

## Why SchemaCache?

Most caching libraries give you a key-value store and leave invalidation up to you. SchemaCache takes a different approach — it understands your Ecto schemas and uses their structure to automatically manage cache keys.

**SMKES** (Schema Mutation Key Eviction Strategy) maintains a mapping between your Ecto schemas and every cache key where they appear. When a schema is mutated (created, updated, or deleted), SchemaCache knows exactly which cached values are affected and evicts or updates them automatically.

This means:
- No stale data from forgotten cache invalidations
- No manual bookkeeping of which keys to evict on writes
- Write-through support that updates cached collections in place
- Automatic collection eviction when new records are created

## Installation

Add `schema_cache` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schema_cache, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure your cache adapter:

```elixir
# config/config.exs
config :schema_cache, adapter: SchemaCache.Adapters.ETS
```

SchemaCache ships with a built-in ETS adapter. You can implement the `SchemaCache.Adapter` behaviour to use any backend (Nebulex, ConCache, Redis, etc.).

## Usage

### Read Through Caching

```elixir
defmodule MyApp.Users do
  @find_user_key "find_user"
  @all_users_key "all_users"
  @ttl :timer.minutes(15)

  def cached_find(params) do
    SchemaCache.read(@find_user_key, params, @ttl, fn ->
      find(params)
    end)
  end

  def cached_all(params \\ %{}) do
    SchemaCache.read(@all_users_key, params, @ttl, fn ->
      all(params)
    end)
  end
end
```

### Mutation with Automatic Eviction

```elixir
defmodule MyApp.Users do
  # Evicts all cached collections when a new user is created
  def create(params) do
    SchemaCache.mutate(
      fn -> Actions.create(User, params) end,
      behavior: :new_schema
    )
  end

  # Evicts all cache keys referencing the updated user
  def update(%User{} = user, params) do
    SchemaCache.mutate(fn -> Actions.update(User, user, params) end)
  end

  # Or use write-through to update cached values in place
  def update_write_through(%User{} = user, params) do
    SchemaCache.mutate(
      fn -> Actions.update(User, user, params) end,
      behavior: :write_through
    )
  end

  def delete(user) do
    SchemaCache.mutate(fn -> Actions.delete(User, user) end)
  end
end
```

## Custom Adapters

Implement the `SchemaCache.Adapter` behaviour to use your preferred caching backend:

```elixir
defmodule MyApp.RedisAdapter do
  @behaviour SchemaCache.Adapter

  @impl true
  def get(key), do: # ...

  @impl true
  def put(key, ttl, value), do: # ...

  # ... implement all callbacks
end
```

## Documentation

Full documentation is available on [HexDocs](https://hexdocs.pm/schema_cache).

## License

MIT License. See [LICENSE](LICENSE) for details.
