defmodule SchemaCache.KeyGenerator do
  @moduledoc """
  Generates deterministic cache keys from Ecto schema structs and query
  parameters.

  This module is used internally by `SchemaCache` to produce two types
  of keys:

    * **Cache keys** (`cache_key/2`): combine a caller-provided string
      prefix with JSON-encoded query parameters to uniquely identify a
      cached query result. For example, `"find_user"` + `%{id: 5}`
      produces `"find_user:{\"id\":5}"`.

    * **Schema cache keys** (`schema_cache_key/1`): identify a specific
      Ecto schema instance by its module name and primary key values.
      These keys are used as set identifiers in SMKES to track which
      cache keys reference a given schema. For example,
      `%MyApp.User{id: 5}` produces `"Elixir.MyApp.User:5"`. Composite
      primary keys are joined with colons.
  """

  @doc ~S"""
  Builds a cache key from a string prefix and a map of query parameters.

  The params map is JSON-encoded and appended to the prefix, separated
  by a colon. Keyword list values under the `:order_by` key are
  automatically converted to maps before encoding to ensure consistent
  key generation regardless of keyword list ordering.

  ## Examples

      iex> SchemaCache.KeyGenerator.cache_key("users", %{id: 5})
      "users:{\"id\":5}"

      iex> SchemaCache.KeyGenerator.cache_key("foo", %{order_by: [fiz: "buz"]})
      "foo:{\"order_by\":{\"fiz\":\"buz\"}}"

      iex> SchemaCache.KeyGenerator.cache_key("users", %{})
      "users:{}"

  """
  @spec cache_key(String.t(), map()) :: String.t()
  def cache_key(key, params) do
    params
    |> maybe_convert_order_by_into_map()
    |> then(&"#{key}:#{Jason.encode!(&1)}")
  end

  @doc ~S"""
  Builds a schema identity key from an Ecto struct.

  The key is formed by concatenating the full module name with the
  primary key value(s), separated by colons. This key uniquely
  identifies a schema instance and is used as the set identifier in
  SMKES to track which cache keys reference this specific record.

  Composite primary keys are supported; each primary key field value
  is joined with a colon in the order defined by the schema.

  ## Examples

      iex> SchemaCache.KeyGenerator.schema_cache_key(%SchemaCache.Test.FakeSchema{id: 1})
      "Elixir.SchemaCache.Test.FakeSchema:1"

  """
  @spec schema_cache_key(struct()) :: String.t()
  def schema_cache_key(%schema{} = value) do
    schema.__schema__(:primary_key)
    |> Enum.map_join(":", &Map.get(value, &1))
    |> then(&"#{schema}:#{&1}")
  end

  defp maybe_convert_order_by_into_map(%{order_by: order_by} = params) do
    Map.put(params, :order_by, Enum.into(order_by, %{}))
  end

  defp maybe_convert_order_by_into_map(params), do: params
end
