defmodule SchemaCache.Adapters.RedisAdapterTest do
  @moduledoc false

  use SchemaCache.Test.RedisCase, async: false

  alias SchemaCache.Test.RedisAdapter

  describe "get/1" do
    test "returns {:ok, nil} for missing keys" do
      assert {:ok, nil} = RedisAdapter.get("nonexistent")
    end

    test "returns {:ok, value} for existing keys" do
      RedisAdapter.put("key", "value", [])
      assert {:ok, "value"} = RedisAdapter.get("key")
    end

    test "round-trips complex Elixir terms" do
      value = %{nested: [1, :atom, {"tuple"}], binary: <<0, 255>>}
      RedisAdapter.put("complex", value, [])
      assert {:ok, ^value} = RedisAdapter.get("complex")
    end
  end

  describe "put/3" do
    test "stores and retrieves values" do
      assert :ok = RedisAdapter.put("key", %{data: true}, [])
      assert {:ok, %{data: true}} = RedisAdapter.get("key")
    end

    test "overwrites existing values" do
      RedisAdapter.put("key", "first", [])
      RedisAdapter.put("key", "second", [])
      assert {:ok, "second"} = RedisAdapter.get("key")
    end

    test "supports TTL option" do
      assert :ok = RedisAdapter.put("ttl_key", "value", ttl: 60_000)
      assert {:ok, "value"} = RedisAdapter.get("ttl_key")
    end
  end

  describe "delete/1" do
    test "removes a key" do
      RedisAdapter.put("key", "value", [])
      assert :ok = RedisAdapter.delete("key")
      assert {:ok, nil} = RedisAdapter.get("key")
    end

    test "returns :ok for nonexistent keys" do
      assert :ok = RedisAdapter.delete("nonexistent")
    end
  end
end
