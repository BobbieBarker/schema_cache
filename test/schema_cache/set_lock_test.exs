defmodule SchemaCache.SetLockTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias SchemaCache.SetLock

  # These test the fallback serialization mechanism for adapters
  # without native set operations. SetLock uses a partitioned lock
  # Registry to serialize read-modify-write cycles on sets stored
  # as MapSets in the adapter's key-value store.

  setup do
    if :ets.whereis(:schema_cache_ets) != :undefined do
      :ets.delete_all_objects(:schema_cache_ets)
    end

    Application.put_env(:schema_cache, :adapter, SchemaCache.Adapters.ETS)
    :ok
  end

  describe "sadd/3" do
    test "adds a member to a set" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "member_1", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert "member_1" in members
    end

    test "does not duplicate members" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "member_1", adapter)
      SetLock.sadd("my_set", "member_1", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert length(members) == 1
    end

    test "adds multiple different members" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "member_1", adapter)
      SetLock.sadd("my_set", "member_2", adapter)
      SetLock.sadd("my_set", "member_3", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert length(members) == 3
      assert "member_1" in members
      assert "member_2" in members
      assert "member_3" in members
    end

    test "handles concurrent adds to the same set without lost writes" do
      adapter = SchemaCache.Adapters.ETS

      # Spawn 50 tasks all adding different members to the same set
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            SetLock.sadd("concurrent_set", "member_#{i}", adapter)
          end)
        end

      Task.await_many(tasks)

      assert {:ok, members} = SetLock.smembers("concurrent_set", adapter)
      # ALL 50 members should be present -- no lost writes
      assert length(members) == 50
    end
  end

  describe "srem/3" do
    test "removes a member from a set" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "member_1", adapter)
      SetLock.sadd("my_set", "member_2", adapter)

      SetLock.srem("my_set", "member_1", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert "member_2" in members
      refute "member_1" in members
    end

    test "removing last member results in nil (empty set)" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "only_member", adapter)

      SetLock.srem("my_set", "only_member", adapter)

      assert {:ok, nil} = SetLock.smembers("my_set", adapter)
    end

    test "removing a non-existent member is a no-op" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "member_1", adapter)

      SetLock.srem("my_set", "nonexistent", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert length(members) == 1
      assert "member_1" in members
    end

    test "handles concurrent adds and removes without corruption" do
      adapter = SchemaCache.Adapters.ETS

      # Pre-populate with 50 members
      for i <- 1..50 do
        SetLock.sadd("race_set", "member_#{i}", adapter)
      end

      # Concurrently: remove evens, add 50 more
      tasks =
        for i <- 1..50, rem(i, 2) == 0 do
          Task.async(fn -> SetLock.srem("race_set", "member_#{i}", adapter) end)
        end ++
          for i <- 51..100 do
            Task.async(fn -> SetLock.sadd("race_set", "member_#{i}", adapter) end)
          end

      Task.await_many(tasks)

      assert {:ok, members} = SetLock.smembers("race_set", adapter)
      # Should have: 25 odd originals + 50 new = 75
      assert length(members) == 75
    end
  end

  describe "smembers/2" do
    test "returns {:ok, nil} for non-existent set" do
      adapter = SchemaCache.Adapters.ETS
      assert {:ok, nil} = SetLock.smembers("nonexistent_set", adapter)
    end

    test "returns {:ok, list} for populated set" do
      adapter = SchemaCache.Adapters.ETS
      SetLock.sadd("my_set", "a", adapter)
      SetLock.sadd("my_set", "b", adapter)

      assert {:ok, members} = SetLock.smembers("my_set", adapter)
      assert is_list(members)
      assert length(members) == 2
    end
  end

  describe "mget/2" do
    test "fetches multiple keys in a single operation" do
      adapter = SchemaCache.Adapters.ETS
      adapter.put("key_1", "value_1", [])
      adapter.put("key_2", "value_2", [])
      adapter.put("key_3", "value_3", [])

      assert {:ok, results} = SetLock.mget(["key_1", "key_2", "key_3"], adapter)
      assert results == ["value_1", "value_2", "value_3"]
    end

    test "returns nil for missing keys" do
      adapter = SchemaCache.Adapters.ETS
      adapter.put("key_1", "value_1", [])

      assert {:ok, results} = SetLock.mget(["key_1", "missing_key"], adapter)
      assert results == ["value_1", nil]
    end
  end
end
