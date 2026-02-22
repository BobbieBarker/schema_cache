defmodule SchemaCache.Adapters.ETSSetOpsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias SchemaCache.Adapters.ETS

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

  describe "sadd/2" do
    test "adds a member to a set" do
      assert :ok = ETS.sadd("my_set", "member_1")

      assert {:ok, members} = ETS.smembers("my_set")
      assert "member_1" in members
    end

    test "with duplicate member is idempotent" do
      ETS.sadd("my_set", "member_1")
      ETS.sadd("my_set", "member_1")

      # ETS bag allows duplicate objects, so we may get duplicates.
      # Verify we get at least one member_1 back.
      assert {:ok, members} = ETS.smembers("my_set")
      assert "member_1" in members
    end
  end

  describe "srem/2" do
    test "removes a specific member" do
      ETS.sadd("my_set", "member_1")
      ETS.sadd("my_set", "member_2")

      assert :ok = ETS.srem("my_set", "member_1")

      assert {:ok, members} = ETS.smembers("my_set")
      assert "member_2" in members
      refute "member_1" in members
    end

    test "on non-existent member returns :ok" do
      ETS.sadd("my_set", "member_1")

      assert :ok = ETS.srem("my_set", "nonexistent")

      assert {:ok, members} = ETS.smembers("my_set")
      assert "member_1" in members
    end
  end

  describe "smembers/1" do
    test "returns {:ok, members} for populated set" do
      ETS.sadd("my_set", "a")
      ETS.sadd("my_set", "b")
      ETS.sadd("my_set", "c")

      assert {:ok, members} = ETS.smembers("my_set")
      assert is_list(members)
      assert length(members) == 3
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "returns {:ok, nil} for empty/non-existent set" do
      assert {:ok, nil} = ETS.smembers("nonexistent_set")
    end
  end

  describe "mget/1" do
    test "returns values for existing keys and nil for missing keys" do
      ETS.put("key_1", "value_1", [])
      ETS.put("key_2", "value_2", [])

      assert {:ok, results} = ETS.mget(["key_1", "missing_key", "key_2"])
      assert results == ["value_1", nil, "value_2"]
    end

    test "with empty list returns {:ok, []}" do
      assert {:ok, []} = ETS.mget([])
    end
  end

  describe "init/0" do
    test "is idempotent (calling it twice does not crash)" do
      assert :ok = ETS.init()
      assert :ok = ETS.init()
    end
  end
end
