defmodule SchemaCache.AdapterDispatchTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias SchemaCache.Adapter

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

  defmodule MinimalAdapter do
    @moduledoc false
    @behaviour SchemaCache.Adapter

    @impl true
    def get(key) do
      case :ets.lookup(:schema_cache_ets, key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:ok, nil}
      end
    end

    @impl true
    def put(key, value, _opts) do
      :ets.insert(:schema_cache_ets, {key, value})
      :ok
    end

    @impl true
    def delete(key) do
      :ets.delete(:schema_cache_ets, key)
      :ok
    end
  end

  describe "sadd/3" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end)

      :ok
    end

    test "routes through SetLock when adapter lacks native sadd" do
      Adapter.resolve_capabilities(MinimalAdapter)

      assert :ok = Adapter.sadd(MinimalAdapter, "test_set", "member_1")

      # Verify the member was stored via SetLock (as a MapSet in the KV store)
      assert {:ok, %MapSet{} = set} = MinimalAdapter.get("test_set")
      assert MapSet.member?(set, "member_1")
    end

    test "goes native with ETS adapter" do
      adapter = SchemaCache.Adapters.ETS
      Adapter.resolve_capabilities(adapter)

      assert :ok = Adapter.sadd(adapter, "native_set", "member_1")

      # Native ETS adapter uses the :bag table, not a MapSet in the :set table.
      # Verify through smembers which also goes native.
      assert {:ok, members} = Adapter.smembers(adapter, "native_set")
      assert "member_1" in members
    end
  end

  describe "srem/3" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end)

      :ok
    end

    test "routes through SetLock when adapter lacks native srem" do
      Adapter.resolve_capabilities(MinimalAdapter)

      Adapter.sadd(MinimalAdapter, "test_set", "member_1")
      Adapter.sadd(MinimalAdapter, "test_set", "member_2")

      assert :ok = Adapter.srem(MinimalAdapter, "test_set", "member_1")

      assert {:ok, %MapSet{} = set} = MinimalAdapter.get("test_set")
      refute MapSet.member?(set, "member_1")
      assert MapSet.member?(set, "member_2")
    end

    test "goes native with ETS adapter" do
      adapter = SchemaCache.Adapters.ETS
      Adapter.resolve_capabilities(adapter)

      Adapter.sadd(adapter, "native_set", "member_1")
      Adapter.sadd(adapter, "native_set", "member_2")

      assert :ok = Adapter.srem(adapter, "native_set", "member_1")

      assert {:ok, members} = Adapter.smembers(adapter, "native_set")
      refute "member_1" in members
      assert "member_2" in members
    end
  end

  describe "smembers/2" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end)

      :ok
    end

    test "routes through SetLock when adapter lacks native smembers" do
      Adapter.resolve_capabilities(MinimalAdapter)

      Adapter.sadd(MinimalAdapter, "test_set", "a")
      Adapter.sadd(MinimalAdapter, "test_set", "b")

      assert {:ok, members} = Adapter.smembers(MinimalAdapter, "test_set")
      assert is_list(members)
      assert "a" in members
      assert "b" in members
    end

    test "goes native with ETS adapter" do
      adapter = SchemaCache.Adapters.ETS
      Adapter.resolve_capabilities(adapter)

      adapter.sadd("native_set", "x")
      adapter.sadd("native_set", "y")

      assert {:ok, members} = Adapter.smembers(adapter, "native_set")
      assert is_list(members)
      assert "x" in members
      assert "y" in members
    end
  end

  describe "mget/2" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end)

      :ok
    end

    test "routes through SetLock when adapter lacks native mget" do
      Adapter.resolve_capabilities(MinimalAdapter)

      MinimalAdapter.put("key_1", "value_1", [])
      MinimalAdapter.put("key_2", "value_2", [])

      assert {:ok, results} = Adapter.mget(MinimalAdapter, ["key_1", "missing", "key_2"])
      assert results == ["value_1", nil, "value_2"]
    end

    test "goes native with ETS adapter" do
      adapter = SchemaCache.Adapters.ETS
      Adapter.resolve_capabilities(adapter)

      adapter.put("k1", "v1", [])
      adapter.put("k2", "v2", [])

      assert {:ok, results} = Adapter.mget(adapter, ["k1", "missing", "k2"])
      assert results == ["v1", nil, "v2"]
    end
  end
end
