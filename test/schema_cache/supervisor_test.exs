defmodule SchemaCache.SupervisorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias SchemaCache.Adapters.ETS

  setup do
    for table <- ETS.managed_tables() do
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end

    :ok
  end

  describe "start_link/1" do
    test "adapter is set in persistent_term after startup" do
      assert ETS = :persistent_term.get(:schema_cache_adapter)
    end

    test "adapter capabilities are set with correct flags for ETS adapter" do
      assert %{
               native_sadd: true,
               native_srem: true,
               native_smembers: true,
               native_mget: true
             } = :persistent_term.get(:schema_cache_adapter_caps)
    end

    test "KeyRegistry ETS tables exist after startup" do
      assert :ets.whereis(:schema_cache_key_to_id) != :undefined
      assert :ets.whereis(:schema_cache_id_to_key) != :undefined
    end

    test "SetLock.Registry is running" do
      assert Process.whereis(SchemaCache.SetLock.Registry) != nil
    end

    test "raises ArgumentError when adapter is not provided" do
      assert_raise ArgumentError, ~r/adapter not configured/, fn ->
        SchemaCache.Supervisor.init([])
      end
    end

    test "capabilities include elixir_cache flags" do
      assert %{
               elixir_cache: false,
               redis_backed: false
             } = :persistent_term.get(:schema_cache_adapter_caps)
    end
  end
end
