defmodule SchemaCache.AdapterDispatchTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias SchemaCache.Adapter
  alias SchemaCache.Adapters.ETS

  setup do
    for table <- ETS.managed_tables() do
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
      adapter = ETS
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
      adapter = ETS
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
      adapter = ETS
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
      adapter = ETS
      Adapter.resolve_capabilities(adapter)

      adapter.put("k1", "v1", [])
      adapter.put("k2", "v2", [])

      assert {:ok, results} = Adapter.mget(adapter, ["k1", "missing", "k2"])
      assert results == ["v1", nil, "v2"]
    end
  end

  describe "resolve_capabilities/1" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end)

      :ok
    end

    test "detects ElixirCache ETS module via @behaviour Cache" do
      Adapter.resolve_capabilities(SchemaCache.Test.ElixirCacheETS)

      assert %{
               elixir_cache: true,
               redis_backed: false,
               native_sadd: false,
               native_mget: false
             } = :persistent_term.get(:schema_cache_adapter_caps)
    end

    test "detects ElixirCache Redis module" do
      Adapter.resolve_capabilities(SchemaCache.Test.ElixirCacheRedis)

      assert %{
               elixir_cache: true,
               redis_backed: true,
               native_sadd: false,
               native_mget: false
             } = :persistent_term.get(:schema_cache_adapter_caps)
    end

    test "native adapter has no elixir_cache flags" do
      Adapter.resolve_capabilities(ETS)

      assert %{
               elixir_cache: false,
               redis_backed: false,
               native_sadd: true,
               native_mget: true
             } = :persistent_term.get(:schema_cache_adapter_caps)
    end
  end

  describe "ElixirCache ETS dispatch" do
    setup do
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)
      Adapter.resolve_capabilities(SchemaCache.Test.ElixirCacheETS)

      on_exit(fn ->
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)

        if :ets.whereis(:schema_cache_test_ec_ets) != :undefined do
          :ets.delete_all_objects(:schema_cache_test_ec_ets)
        end
      end)

      :ok
    end

    test "put/4 with nil TTL" do
      adapter = SchemaCache.Test.ElixirCacheETS

      assert :ok = Adapter.put(adapter, "key", "value", nil)
      assert {:ok, "value"} = adapter.get("key")
    end

    test "put/4 with TTL" do
      adapter = SchemaCache.Test.ElixirCacheETS

      assert :ok = Adapter.put(adapter, "key", "value", 60_000)
      assert {:ok, "value"} = adapter.get("key")
    end

    test "put_no_ttl/3" do
      adapter = SchemaCache.Test.ElixirCacheETS

      assert :ok = Adapter.put_no_ttl(adapter, "key", "value")
      assert {:ok, "value"} = adapter.get("key")
    end

    test "get/2" do
      adapter = SchemaCache.Test.ElixirCacheETS

      adapter.put("key", "value")
      assert {:ok, "value"} = Adapter.get(adapter, "key")
    end

    test "delete/2" do
      adapter = SchemaCache.Test.ElixirCacheETS

      adapter.put("key", "value")
      assert :ok = Adapter.delete(adapter, "key")
      assert {:ok, nil} = adapter.get("key")
    end

    test "round-trips complex Elixir terms" do
      adapter = SchemaCache.Test.ElixirCacheETS
      value = %{nested: [1, :atom, {"tuple"}], binary: <<0, 255>>}

      Adapter.put(adapter, "complex", value, nil)
      assert {:ok, ^value} = Adapter.get(adapter, "complex")
    end

    test "set operations fall through to SetLock" do
      adapter = SchemaCache.Test.ElixirCacheETS

      Adapter.sadd(adapter, "my_set", "member_1")
      Adapter.sadd(adapter, "my_set", "member_2")

      assert {:ok, members} = Adapter.smembers(adapter, "my_set")
      assert "member_1" in members
      assert "member_2" in members
    end

    test "mget falls through to SetLock" do
      adapter = SchemaCache.Test.ElixirCacheETS

      Adapter.put(adapter, "k1", "v1", nil)
      Adapter.put(adapter, "k2", "v2", nil)

      assert {:ok, ["v1", nil, "v2"]} =
               Adapter.mget(adapter, ["k1", "missing", "k2"])
    end
  end

  describe "ElixirCache Redis dispatch" do
    setup do
      redis_url =
        Application.get_env(
          :schema_cache,
          :redis_url,
          "redis://localhost:6379"
        )

      with {:ok, conn} <- Redix.start_link(redis_url),
           {:ok, "OK"} <- Redix.command(conn, ["FLUSHDB"]) do
        GenServer.stop(conn)

        start_supervised!(SchemaCache.Test.ElixirCacheRedis)

        original_caps = :persistent_term.get(:schema_cache_adapter_caps)
        Adapter.resolve_capabilities(SchemaCache.Test.ElixirCacheRedis)

        on_exit(fn ->
          :persistent_term.put(:schema_cache_adapter_caps, original_caps)
        end)

        :ok
      else
        _ -> :skip
      end
    end

    @tag :redis
    test "sadd/srem/smembers route through command/1" do
      adapter = SchemaCache.Test.ElixirCacheRedis

      assert :ok = Adapter.sadd(adapter, "my_set", 42)
      assert :ok = Adapter.sadd(adapter, "my_set", 99)

      assert {:ok, members} = Adapter.smembers(adapter, "my_set")
      assert 42 in members
      assert 99 in members

      assert :ok = Adapter.srem(adapter, "my_set", 42)

      assert {:ok, members} = Adapter.smembers(adapter, "my_set")
      refute 42 in members
      assert 99 in members
    end

    @tag :redis
    test "mget falls through to SetLock (individual gets)" do
      adapter = SchemaCache.Test.ElixirCacheRedis

      Adapter.put(adapter, "k1", "v1", nil)
      Adapter.put(adapter, "k2", "v2", nil)

      assert {:ok, ["v1", nil, "v2"]} =
               Adapter.mget(adapter, ["k1", "missing", "k2"])
    end

    @tag :redis
    test "smembers returns {:ok, nil} for empty set" do
      assert {:ok, nil} =
               Adapter.smembers(
                 SchemaCache.Test.ElixirCacheRedis,
                 "nonexistent"
               )
    end
  end
end
