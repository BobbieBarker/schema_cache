defmodule SchemaCache.Adapters.ETSTest do
  use ExUnit.Case, async: false

  alias SchemaCache.Adapters.ETS

  setup do
    if :ets.whereis(:schema_cache_ets) != :undefined do
      :ets.delete_all_objects(:schema_cache_ets)
    end

    :ok
  end

  describe "get/1" do
    test "returns {:ok, nil} for missing keys" do
      assert {:ok, nil} = ETS.get("nonexistent")
    end

    test "returns {:ok, value} for existing keys" do
      ETS.put("key", "value", [])
      assert {:ok, "value"} = ETS.get("key")
    end
  end

  describe "put/3" do
    test "stores and retrieves values" do
      assert :ok = ETS.put("key", %{data: true}, [])
      assert {:ok, %{data: true}} = ETS.get("key")
    end

    test "overwrites existing values" do
      ETS.put("key", "first", [])
      ETS.put("key", "second", [])
      assert {:ok, "second"} = ETS.get("key")
    end
  end

  describe "delete/1" do
    test "removes a key" do
      ETS.put("key", "value", [])
      assert :ok = ETS.delete("key")
      assert {:ok, nil} = ETS.get("key")
    end

    test "returns :ok for nonexistent keys" do
      assert :ok = ETS.delete("nonexistent")
    end
  end
end
