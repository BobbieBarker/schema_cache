defmodule SchemaCache.Adapters.RedisAdapterSetOpsTest do
  @moduledoc false

  use SchemaCache.Test.RedisCase, async: false

  alias SchemaCache.Test.RedisAdapter

  describe "sadd/2" do
    test "adds a member to a set" do
      assert :ok = RedisAdapter.sadd("my_set", 1)

      assert {:ok, members} = RedisAdapter.smembers("my_set")
      assert 1 in members
    end

    test "with duplicate member is idempotent" do
      RedisAdapter.sadd("my_set", 1)
      RedisAdapter.sadd("my_set", 1)

      assert {:ok, members} = RedisAdapter.smembers("my_set")
      assert members == [1]
    end
  end

  describe "srem/2" do
    test "removes a specific member" do
      RedisAdapter.sadd("my_set", 1)
      RedisAdapter.sadd("my_set", 2)

      assert :ok = RedisAdapter.srem("my_set", 1)

      assert {:ok, members} = RedisAdapter.smembers("my_set")
      assert 2 in members
      refute 1 in members
    end

    test "on non-existent member returns :ok" do
      RedisAdapter.sadd("my_set", 1)

      assert :ok = RedisAdapter.srem("my_set", 999)

      assert {:ok, members} = RedisAdapter.smembers("my_set")
      assert 1 in members
    end
  end

  describe "smembers/1" do
    test "returns {:ok, members} for populated set" do
      RedisAdapter.sadd("my_set", 1)
      RedisAdapter.sadd("my_set", 2)
      RedisAdapter.sadd("my_set", 3)

      assert {:ok, members} = RedisAdapter.smembers("my_set")
      assert is_list(members)
      assert 3 = length(members)
      assert Enum.sort(members) == [1, 2, 3]
    end

    test "returns {:ok, nil} for empty/non-existent set" do
      assert {:ok, nil} = RedisAdapter.smembers("nonexistent_set")
    end
  end

  describe "mget/1" do
    test "returns values for existing keys and nil for missing keys" do
      RedisAdapter.put("key_1", "value_1", [])
      RedisAdapter.put("key_2", "value_2", [])

      assert {:ok, results} = RedisAdapter.mget(["key_1", "missing_key", "key_2"])
      assert results == ["value_1", nil, "value_2"]
    end

    test "with empty list returns {:ok, []}" do
      assert {:ok, []} = RedisAdapter.mget([])
    end
  end
end
