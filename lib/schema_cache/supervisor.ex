defmodule SchemaCache.Supervisor do
  @moduledoc """
  Supervisor for the SchemaCache system.

  Add this to your application's supervision tree to initialize the cache
  adapter, resolve adapter capabilities, and start internal processes.

  ## Usage

      children = [
        {SchemaCache.Supervisor, adapter: SchemaCache.Adapters.ETS},
        # ... other children
      ]

  Any module implementing `SchemaCache.Adapter` works, as well as any
  ElixirCache module (detected automatically):

      children = [
        MyApp.Cache,
        {SchemaCache.Supervisor, adapter: MyApp.Cache}
      ]

  """

  use Supervisor

  alias SchemaCache.Adapter

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    adapter =
      Keyword.get(opts, :adapter) ||
        raise ArgumentError,
              """
              SchemaCache adapter not configured.
              Pass adapter: YourAdapter to SchemaCache.Supervisor
              """

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
