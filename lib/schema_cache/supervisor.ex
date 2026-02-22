defmodule SchemaCache.Supervisor do
  @moduledoc false

  use Supervisor

  alias SchemaCache.Adapter

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    adapter =
      with nil <- Keyword.get(opts, :adapter),
           nil <- Application.get_env(:schema_cache, :adapter) do
        raise "SchemaCache adapter not configured. Set config :schema_cache, adapter: YourAdapter"
      end

    :persistent_term.put(:schema_cache_adapter, adapter)

    Adapter.init(adapter)
    Adapter.resolve_capabilities(adapter)

    SchemaCache.KeyRegistry.init()

    children = [
      {Registry,
       keys: :unique, name: SchemaCache.SetLock.Registry, partitions: System.schedulers_online()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
