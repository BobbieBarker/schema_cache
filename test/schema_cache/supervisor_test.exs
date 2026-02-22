defmodule SchemaCache.SupervisorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @ets_tables [
    :schema_cache_ets,
    :schema_cache_ets_sets,
    :schema_cache_key_to_id,
    :schema_cache_id_to_key
  ]

  setup do
    for table <- @ets_tables do
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end

    :ok
  end

  describe "start_link/1" do
    test "adapter is set in persistent_term after startup" do
      assert SchemaCache.Adapters.ETS = :persistent_term.get(:schema_cache_adapter)
    end

    test "adapter capabilities are set with correct flags for ETS adapter" do
      caps = :persistent_term.get(:schema_cache_adapter_caps)

      assert %{sadd: true, srem: true, smembers: true, mget: true} = caps
    end

    test "KeyRegistry ETS tables exist after startup" do
      assert :ets.whereis(:schema_cache_key_to_id) != :undefined
      assert :ets.whereis(:schema_cache_id_to_key) != :undefined
    end

    test "SetLock.Registry is running" do
      assert Process.whereis(SchemaCache.SetLock.Registry) != nil
    end
  end
end
