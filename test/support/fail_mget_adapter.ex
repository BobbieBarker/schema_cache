defmodule SchemaCache.Test.FailMgetAdapter do
  @moduledoc false

  @behaviour SchemaCache.Adapter

  @doc """
  An adapter that delegates all operations to the ETS adapter except `mget/1`,
  which always returns `{:error, :boom}`. Used to test mget error handling paths.
  """

  @impl true
  defdelegate get(key), to: SchemaCache.Adapters.ETS

  @impl true
  defdelegate put(key, value, opts), to: SchemaCache.Adapters.ETS

  @impl true
  defdelegate delete(key), to: SchemaCache.Adapters.ETS

  @impl true
  defdelegate sadd(key, member), to: SchemaCache.Adapters.ETS

  @impl true
  defdelegate srem(key, member), to: SchemaCache.Adapters.ETS

  @impl true
  defdelegate smembers(key), to: SchemaCache.Adapters.ETS

  @impl true
  def mget(_keys), do: {:error, :boom}
end
