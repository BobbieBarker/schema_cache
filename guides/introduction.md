# Introduction to SchemaCache

SchemaCache is an Ecto-aware caching library for Elixir that provides **cache-aside** and **write-through** abstractions with automatic invalidation. When an Ecto schema is mutated, every affected cache entry is evicted or updated. No invalidation logic required.

## Key Features

- **Cache-aside**: On a cache miss, SchemaCache calls your function to fetch from the source and caches the result. When underlying schemas change, affected entries are evicted automatically.
- **Write-through**: When your application can't tolerate stale results, write-through updates cached values in place after mutations.
- **Adapter-agnostic**: Plug in any caching backend (ETS, Redis, Nebulex, Cachex, or your own). Adapters only need `get/1`, `put/3`, and `delete/1`.

## When to Use SchemaCache

SchemaCache is a good fit when:

- Your application caches Ecto query results and can't serve stale data after mutations.
- You want cache-aside with invalidation driven by schema changes.
- You need write-through caching to keep cached values fresh after writes.
- You need a backend-agnostic caching layer that works with any storage engine.

## Getting Started

Check out the [installation guide](tutorials/installation.md) to add SchemaCache to your project.
