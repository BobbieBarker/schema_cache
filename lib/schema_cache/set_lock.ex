defmodule SchemaCache.SetLock do
  @moduledoc """
  Partitioned lock fallback for adapters without native set operations.

  When an adapter does not implement the optional `sadd/2`, `srem/2`, and
  `smembers/1` callbacks, SchemaCache routes set operations through this
  module. It serializes read-modify-write cycles using a partitioned
  `Registry` as a lock pool, storing sets as `MapSet` values in the
  adapter's key-value store.

  The lock is partitioned by `System.schedulers_online/0` to reduce
  contention. Concurrent writes to different set keys rarely contend,
  while writes to the same key are serialized by hashing to the same
  partition.
  """

  @registry SchemaCache.SetLock.Registry
  @max_retries 100
  @retry_sleep 1
  @lock_partition_multiplier 4

  @spec locked_update(String.t(), module(), (MapSet.t() -> MapSet.t())) :: :ok
  def locked_update(set_key, adapter, update_fn) do
    set_key
    |> :erlang.phash2(System.schedulers_online() * @lock_partition_multiplier)
    |> do_locked_update(set_key, adapter, update_fn, 0)
  end

  defp do_locked_update(_lock_key, _set_key, _adapter, _update_fn, @max_retries) do
    raise "SchemaCache.SetLock: timed out acquiring lock"
  end

  defp do_locked_update(lock_key, set_key, adapter, update_fn, attempt) do
    case Registry.register(@registry, lock_key, nil) do
      {:ok, _} ->
        try do
          set_key
          |> adapter.get()
          |> current_set()
          |> update_fn.()
          |> then(&adapter.put(set_key, &1, []))

          :ok
        after
          Registry.unregister(@registry, lock_key)
        end

      {:error, _} ->
        Process.sleep(@retry_sleep)
        do_locked_update(lock_key, set_key, adapter, update_fn, attempt + 1)
    end
  end

  defp current_set({:ok, %MapSet{} = set}), do: set
  defp current_set(_), do: MapSet.new()

  @spec sadd(String.t(), term(), module()) :: :ok
  def sadd(set_key, member, adapter) do
    locked_update(set_key, adapter, &MapSet.put(&1, member))
  end

  @spec srem(String.t(), term(), module()) :: :ok
  def srem(set_key, member, adapter) do
    locked_update(set_key, adapter, &MapSet.delete(&1, member))
  end

  @spec smembers(String.t(), module()) :: {:ok, list() | nil} | {:error, any()}
  def smembers(set_key, adapter) do
    set_key
    |> adapter.get()
    |> format_smembers_result()
  end

  defp format_smembers_result({:ok, %MapSet{} = set}) do
    set
    |> MapSet.to_list()
    |> case do
      [] -> {:ok, nil}
      members -> {:ok, members}
    end
  end

  defp format_smembers_result({:ok, nil}), do: {:ok, nil}
  defp format_smembers_result(error), do: error

  @spec mget([String.t()], module()) :: {:ok, [any() | nil]}
  def mget(keys, adapter) do
    keys
    |> Enum.map(fn key ->
      case adapter.get(key) do
        {:ok, value} -> value
        _ -> nil
      end
    end)
    |> then(&{:ok, &1})
  end
end
