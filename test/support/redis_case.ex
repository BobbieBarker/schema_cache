defmodule SchemaCache.Test.RedisCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias SchemaCache.Adapter

  @ets_tables [
    :schema_cache_ets,
    :schema_cache_ets_sets,
    :schema_cache_key_to_id,
    :schema_cache_id_to_key
  ]

  setup do
    redis_url = Application.get_env(:schema_cache, :redis_url, "redis://localhost:6379")

    case Redix.start_link(redis_url) do
      {:ok, conn} ->
        {:ok, "OK"} = Redix.command(conn, ["FLUSHDB"])

        for table <- @ets_tables do
          if :ets.whereis(table) != :undefined do
            :ets.delete_all_objects(table)
          end
        end

        Process.put(:schema_cache_redis_conn, conn)

        original_adapter = :persistent_term.get(:schema_cache_adapter)
        original_caps = :persistent_term.get(:schema_cache_adapter_caps)

        :persistent_term.put(:schema_cache_adapter, SchemaCache.Test.RedisAdapter)
        Adapter.resolve_capabilities(SchemaCache.Test.RedisAdapter)

        on_exit(fn ->
          :persistent_term.put(:schema_cache_adapter, original_adapter)
          :persistent_term.put(:schema_cache_adapter_caps, original_caps)

          if Process.alive?(conn), do: GenServer.stop(conn)
        end)

        %{redis_conn: conn}

      {:error, _reason} ->
        :skip
    end
  end
end
