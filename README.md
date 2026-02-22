# SchemaCache

[![Hex.pm](https://img.shields.io/hexpm/v/schema_cache.svg)](https://hex.pm/packages/schema_cache)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/schema_cache)
[![CI](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/BobbieBarker/schema_cache/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/BobbieBarker/schema_cache/branch/main/graph/badge.svg)](https://codecov.io/gh/BobbieBarker/schema_cache)

An Ecto-aware caching library providing **cache-aside** and **write-through**
abstractions with automatic invalidation.

SchemaCache understands the relationship between your Ecto schemas and cached
query results. When a schema is mutated, it knows exactly which cached values
are affected and can evict or update them automatically.

## Installation

Add `schema_cache` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schema_cache, "~> 0.1.0"}
  ]
end
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

### Cache-Aside

On a cache miss, SchemaCache invokes your callback to fetch from the source,
caches the result, and records which schemas appear in it for later eviction.

```elixir
# Cache a single record
{:ok, user} =
  SchemaCache.read("find_user", %{id: 5}, :timer.minutes(15), fn ->
    MyApp.Users.find(%{id: 5})
  end)

# Cache a collection (prefix with "all_" for write-through support)
{:ok, users} =
  SchemaCache.read("all_active_users", %{active: true}, :timer.minutes(5), fn ->
    {:ok, MyApp.Users.all(%{active: true})}
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

### Update with Write-Through

Update all cached values referencing the schema in place, avoiding cache misses
entirely. Use when your application can't serve stale results after a write.

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

## How It Works

SchemaCache maintains a reverse index from Ecto schemas to cache keys (SMKES).
When a query result is cached, it records which schemas appear in that result.
On mutation, it looks up all affected cache keys and evicts or updates them.

For a detailed explanation, see the
[Architecture Guide](guides/explanation/architecture.md).

## Using with ElixirCache

[ElixirCache](https://github.com/MikaAK/elixir_cache) modules work out of the
box. No wrapper module needed. SchemaCache auto-detects ElixirCache modules and
translates API signatures automatically:

```elixir
children = [
  MyApp.Cache,
  {SchemaCache.Supervisor, adapter: MyApp.Cache}
]
```

For Redis-backed ElixirCache modules, SchemaCache also auto-detects native set
operations via `command/1` with zero configuration. See the
[ElixirCache Integration Guide](guides/how-to/using_with_elixir_cache.md)
for details.

## Documentation

- [Introduction](guides/introduction.md)
- **Tutorials**: [Installation](guides/tutorials/installation.md) | [Basic Operations](guides/tutorials/basic_operations.md)
- **How-to**: [Writing Adapters](guides/how-to/writing_adapters.md) | [Using with ElixirCache](guides/how-to/using_with_elixir_cache.md)
- **Explanation**: [Architecture (SMKES)](guides/explanation/architecture.md)
- [HexDocs](https://hexdocs.pm/schema_cache)

## Contributing

### Prerequisites

- Elixir ~> 1.14
- PostgreSQL (for integration tests)
- Redis (optional, for Redis adapter tests)
- Docker (optional, for running services via docker-compose)

### Local Setup

```bash
# Clone the repository
git clone https://github.com/BobbieBarker/schema_cache.git
cd schema_cache

# Install dependencies
mix deps.get

# Create and migrate the test database
MIX_ENV=test mix ecto.setup

# Run the test suite
mix test
```

### Running Redis Tests

Redis adapter tests require a running Redis instance. You can start one with
docker-compose:

```bash
docker-compose up -d redis
mix test
```

Tests that require Redis will automatically skip if Redis is not available.

### Code Quality

```bash
# Linting
mix credo

# Type checking
mix dialyzer

# Test coverage
mix coveralls
```

### Pull Requests

1. Fork the repository and create your branch from `main`.
2. Write tests for any new functionality.
3. Ensure `mix test`, `mix credo`, and `mix dialyzer` pass.
4. Open a pull request with a clear description of the change.

## License

MIT License. See [LICENSE](LICENSE) for details.
