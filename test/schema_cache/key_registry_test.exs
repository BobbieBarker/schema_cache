defmodule SchemaCache.KeyRegistryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias SchemaCache.KeyRegistry

  # NOTE: These tests will fail until KeyRegistry is implemented and its
  # GenServer is started via SchemaCache.Supervisor. They define the
  # expected contract for the bidirectional cache_key <-> integer ID mapping.

  describe "register/1" do
    test "returns an integer ID for a cache key" do
      id = KeyRegistry.register("find_user:{\"id\":1}")
      assert is_integer(id)
    end

    test "returns the same ID for the same key" do
      id1 = KeyRegistry.register("find_user:{\"id\":1}")
      id2 = KeyRegistry.register("find_user:{\"id\":1}")
      assert id1 == id2
    end

    test "returns different IDs for different keys" do
      id1 = KeyRegistry.register("find_user:{\"id\":1}")
      id2 = KeyRegistry.register("find_user:{\"id\":2}")
      assert id1 != id2
    end

    test "handles concurrent registrations of the same key" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> KeyRegistry.register("concurrent_key") end)
        end

      ids = Task.await_many(tasks)
      # All should get the same ID
      assert Enum.uniq(ids) |> length() == 1
    end

    test "handles concurrent registrations of different keys" do
      tasks =
        for i <- 1..100 do
          Task.async(fn -> KeyRegistry.register("key_#{i}") end)
        end

      ids = Task.await_many(tasks)
      # All should be unique
      assert Enum.uniq(ids) |> length() == 100
    end
  end

  describe "lookup/1" do
    test "returns the cache key for a registered ID" do
      id = KeyRegistry.register("find_user:{\"id\":5}")
      assert {:ok, "find_user:{\"id\":5}"} = KeyRegistry.lookup(id)
    end

    test "returns {:ok, nil} for unknown ID" do
      assert {:ok, nil} = KeyRegistry.lookup(999_999_999)
    end
  end

  describe "resolve/1" do
    test "resolves a list of IDs to {id, key} tuples" do
      id1 = KeyRegistry.register("key_a")
      id2 = KeyRegistry.register("key_b")
      id3 = KeyRegistry.register("key_c")

      result = KeyRegistry.resolve([id1, id2, id3])
      assert {id1, "key_a"} in result
      assert {id2, "key_b"} in result
      assert {id3, "key_c"} in result
    end

    test "filters out stale/unregistered IDs" do
      id1 = KeyRegistry.register("key_a")
      result = KeyRegistry.resolve([id1, 999_999_999])
      assert length(result) == 1
      assert {id1, "key_a"} in result
    end
  end

  describe "unregister/1" do
    test "removes both mappings" do
      id = KeyRegistry.register("temp_key")
      assert {:ok, "temp_key"} = KeyRegistry.lookup(id)

      KeyRegistry.unregister("temp_key")
      assert {:ok, nil} = KeyRegistry.lookup(id)
    end
  end

  describe "unregister_id/1" do
    test "removes entries from both tables" do
      id = KeyRegistry.register("temp_id_key")
      assert {:ok, "temp_id_key"} = KeyRegistry.lookup(id)

      assert :ok = KeyRegistry.unregister_id(id)

      # ID -> key mapping should be gone
      assert {:ok, nil} = KeyRegistry.lookup(id)

      # key -> ID mapping should also be gone (re-registering gives a new ID)
      new_id = KeyRegistry.register("temp_id_key")
      assert new_id != id
    end

    test "with non-existent ID returns :ok" do
      assert :ok = KeyRegistry.unregister_id(888_888_888)
    end
  end

  describe "init/0" do
    test "is idempotent (calling twice does not crash)" do
      assert :ok = KeyRegistry.init()
      assert :ok = KeyRegistry.init()
    end
  end
end
