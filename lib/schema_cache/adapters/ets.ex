defmodule SchemaCache.Adapters.ETS do
  @moduledoc """
  A simple ETS-based cache adapter for single-node usage.

  This adapter uses two named ETS tables:

    * `:schema_cache_ets`: a `:set` table for regular key-value data
    * `:schema_cache_ets_sets`: a `:bag` table for native set operations

  The set table provides atomic `sadd/2`, `srem/2`, and `smembers/1`
  operations backed by ETS `:bag` insert and delete_object, which are
  atomic per-object operations. This avoids the partitioned lock
  fallback used by adapters without native set support.

  This adapter does **not** support TTL. The `:ttl` option in `put/3` is
  accepted but ignored. If you need TTL, use an adapter backed by a
  library that provides it (Nebulex, ConCache, Cachex, etc.).

  ## When to Use

    * Development and testing
    * Single-node deployments where simplicity is preferred
    * Prototyping before integrating a production cache backend

  ## Limitations

    * No TTL support: cached entries persist until explicitly evicted
    * Single-node only, not shared across a cluster
    * No memory limits; the table grows without bound

  ## Usage

      children = [
        {SchemaCache.Supervisor, adapter: SchemaCache.Adapters.ETS}
      ]
  """

  @behaviour SchemaCache.Adapter

  @data_table :schema_cache_ets
  @set_table :schema_cache_ets_sets

  @doc """
  Returns the list of ETS tables managed by this adapter and SchemaCache internals.

  Useful for test cleanup. Call this instead of hardcoding table names.
  """
  @spec managed_tables() :: [atom()]
  def managed_tables do
    [
      @data_table,
      @set_table,
      :schema_cache_key_to_id,
      :schema_cache_id_to_key
    ]
  end

  @impl true
  def init do
    :ets.new(@data_table, [:set, :public, :named_table])
    :ets.new(@set_table, [:bag, :public, :named_table])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def get(key) do
    case :ets.lookup(@data_table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:ok, nil}
    end
  end

  @impl true
  def put(key, value, _opts \\ []) do
    :ets.insert(@data_table, {key, value})
    :ok
  end

  @impl true
  def delete(key) do
    :ets.delete(@data_table, key)
    :ok
  end

  @impl true
  def sadd(key, member) do
    :ets.insert(@set_table, {key, member})
    :ok
  end

  @impl true
  def srem(key, member) do
    :ets.delete_object(@set_table, {key, member})
    :ok
  end

  @impl true
  def smembers(key) do
    @set_table
    |> :ets.lookup(key)
    |> Enum.map(&elem(&1, 1))
    |> case do
      [] -> {:ok, nil}
      members -> {:ok, members}
    end
  end

  @impl true
  def mget(keys) do
    keys
    |> Enum.map(fn key ->
      case :ets.lookup(@data_table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end)
    |> then(&{:ok, &1})
  end
end
