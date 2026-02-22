# How to Use SchemaCache with ElixirCache

[ElixirCache](https://github.com/MikaAK/elixir_cache) provides a standardized caching interface with adapters for ETS, Redis, DETS, ConCache, and more. SchemaCache detects ElixirCache modules automatically and translates API signatures, so you can use them directly. No wrapper module needed.

## Why Use ElixirCache as a Backend?

- **Production-ready Redis support** with connection pooling, hash operations, and JSON commands.
- **Telemetry integration** for cache hit/miss metrics and monitoring.
- **Sandbox mode** for isolated testing with concurrent test support.
- **Consistent interface** if you're already using ElixirCache elsewhere in your application.

## Setup

### 1. Add Dependencies

```elixir
# mix.exs
def deps do
  [
    {:schema_cache, "~> 0.1.0"},
    {:elixir_cache, "~> 0.3.8"}
  ]
end
```

### 2. Define Your ElixirCache Module

```elixir
defmodule MyApp.Cache do
  use Cache,
    adapter: Cache.Redis,
    name: :my_app_cache,
    opts: [
      uri: System.get_env("REDIS_URL", "redis://localhost:6379"),
      pool_size: 10
    ],
    sandbox?: Mix.env() == :test
end
```

### 3. Add Both to Your Supervision Tree

```elixir
def start(_type, _args) do
  children = [
    MyApp.Cache,
    {SchemaCache.Supervisor, adapter: MyApp.Cache},
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

Start `MyApp.Cache` before `SchemaCache.Supervisor` so the backing store is available when SchemaCache initializes.

That's it. No config files, no wrapper modules.

## How Auto-Detection Works

At startup, `SchemaCache.Supervisor` resolves the adapter's capabilities. The detection checks:

1. **ElixirCache module?** Checks `function_exported?(adapter, :cache_adapter, 0)`, which returns `true` for any module created with `use Cache`.
2. **Redis-backed?** If the module is an ElixirCache module AND `adapter.cache_adapter()` returns `Cache.Redis` AND the module exports `command/1`.

### What This Enables

- **API translation**: ElixirCache uses `put(key, value)` and `put(key, ttl, value)` with positional TTL. SchemaCache's adapter behaviour uses `put(key, value, opts)` with keyword TTL. The dispatch layer handles this translation automatically.
- **Native Redis set operations**: For Redis-backed modules, SchemaCache routes `sadd`, `srem`, `smembers`, and `mget` through `command/1` using raw Redis commands. This gives you full SMKES performance without the partitioned lock fallback.

### Capability Summary

| Capability | Local ElixirCache | Redis ElixirCache |
|---|---|---|
| get/put/delete | Auto-translated | Auto-translated |
| sadd/srem/smembers | SetLock fallback | Native via `command/1` |
| mget | Sequential fallback | Native via `command/1` |

## Testing

If your ElixirCache module has `sandbox?: true`, use the sandbox registry in your test setup:

```elixir
# test/test_helper.exs
{:ok, _pid} = Cache.SandboxRegistry.start_link()

# test/support/data_case.ex
setup do
  Cache.SandboxRegistry.start(MyApp.Cache)
  :ok
end
```

This gives each test an isolated cache namespace, preventing interference between concurrent tests.
