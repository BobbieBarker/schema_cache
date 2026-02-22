# Installation

## Adding SchemaCache to Your Project

Add `schema_cache` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schema_cache, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Adding to Your Supervision Tree

Add `SchemaCache.Supervisor` to your application's supervision tree with the
adapter you want to use:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {SchemaCache.Supervisor, adapter: SchemaCache.Adapters.ETS},
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

The supervisor initializes the adapter (creating ETS tables, opening connections, etc.) and starts the `SchemaCache.KeyRegistry` for compact key ID management.

## Verifying Your Installation

Start an IEx session and verify the cache is working:

```elixir
iex> SchemaCache.read("test_key", %{}, :timer.minutes(5), fn -> {:ok, "hello"} end)
{:ok, "hello"}

iex> SchemaCache.read("test_key", %{}, :timer.minutes(5), fn -> {:ok, "this won't run"} end)
{:ok, "hello"}
```

The second call returns the cached value without invoking the callback.

## Next Steps

- Learn the [core operations](basic_operations.md): read, create, update, delete, flush, and write-through.
- Integrate with [ElixirCache](../how-to/using_with_elixir_cache.md) for a full-featured backend.
