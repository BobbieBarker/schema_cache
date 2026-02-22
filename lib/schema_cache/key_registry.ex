defmodule SchemaCache.KeyRegistry do
  @moduledoc """
  Bidirectional mapping between cache key strings and compact integer IDs.

  SMKES reference sets store integer IDs instead of full cache key strings,
  reducing memory usage significantly at scale. A cache key like
  `"all_users:{\"active\":true,\"order_by\":{\"name\":\"asc\"}}"` consumes
  ~80 bytes per set reference; an integer ID consumes ~8 bytes.

  The registry uses two named ETS tables for O(1) lookups in both
  directions:

    * `:schema_cache_key_to_id`: `{cache_key, id}`
    * `:schema_cache_id_to_key`: `{id, cache_key}`

  ID generation uses `:atomics.add_get/3` for lock-free monotonic
  assignment. Concurrent registrations of the same key are safe: the
  first writer wins via `:ets.insert_new/2`, and subsequent callers
  return the existing ID. The losing caller's counter increment is
  never stored, but this is cosmetic; the 64-bit counter space is
  effectively inexhaustible.

  Tables are created by `SchemaCache.Supervisor` during init and owned
  by the supervisor process.
  """

  @key_to_id :schema_cache_key_to_id
  @id_to_key :schema_cache_id_to_key

  @doc false
  def init do
    ensure_table(@key_to_id, :set)
    ensure_table(@id_to_key, :set)

    unless :persistent_term.get(:schema_cache_key_registry_counter, nil) do
      :persistent_term.put(
        :schema_cache_key_registry_counter,
        :atomics.new(1, signed: true)
      )
    end

    :ok
  end

  @spec register(String.t()) :: integer()
  def register(cache_key) do
    :schema_cache_key_registry_counter
    |> :persistent_term.get()
    |> :atomics.add_get(1, 1)
    |> try_insert(cache_key)
  end

  defp try_insert(id, cache_key) do
    case :ets.insert_new(@key_to_id, {cache_key, id}) do
      true ->
        :ets.insert(@id_to_key, {id, cache_key})
        id

      false ->
        case :ets.lookup(@key_to_id, cache_key) do
          [{^cache_key, existing_id}] -> existing_id
          [] -> try_insert(id, cache_key)
        end
    end
  end

  @spec lookup(integer()) :: {:ok, String.t() | nil}
  def lookup(id) do
    case :ets.lookup(@id_to_key, id) do
      [{^id, cache_key}] -> {:ok, cache_key}
      [] -> {:ok, nil}
    end
  end

  @spec resolve([integer()]) :: [{integer(), String.t()}]
  def resolve(ids) do
    Enum.reduce(ids, [], fn id, acc ->
      case :ets.lookup(@id_to_key, id) do
        [{^id, cache_key}] -> [{id, cache_key} | acc]
        [] -> acc
      end
    end)
  end

  @spec unregister(String.t()) :: :ok
  def unregister(cache_key) do
    case :ets.lookup(@key_to_id, cache_key) do
      [{^cache_key, id}] ->
        :ets.delete(@key_to_id, cache_key)
        :ets.delete(@id_to_key, id)

      [] ->
        :ok
    end

    :ok
  end

  @spec unregister_id(integer()) :: :ok
  def unregister_id(id) do
    case :ets.lookup(@id_to_key, id) do
      [{^id, cache_key}] ->
        :ets.delete(@id_to_key, id)
        :ets.delete(@key_to_id, cache_key)

      [] ->
        :ok
    end

    :ok
  end

  defp ensure_table(name, type) do
    :ets.new(name, [type, :public, :named_table])
  rescue
    ArgumentError -> name
  end
end
