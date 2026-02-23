defmodule SchemaCache do
  @moduledoc """
  An Ecto-aware caching library providing cache-aside and write-through
  abstractions with automatic invalidation.

  ## How Invalidation Works

  SchemaCache maintains a reverse index from Ecto schemas to cache keys
  (SMKES). When a query result is cached via `read/4`, it records which
  schemas appear in that result. On mutation, it looks up all cache keys
  referencing the mutated schema and takes action:

    * **`create/1`**: evicts every cached collection for the schema
      type, so the next read includes the new record.
    * **`update/2`** with `:evict` (default): deletes every cached
      entry referencing the mutated schema instance.
    * **`update/2`** with `:write_through`: updates every cached entry
      in place with the new schema value. Use when your application
      can't serve stale results.
    * **`delete/1`**: deletes every cached entry referencing the
      deleted schema instance.

  ## Adapter

  SchemaCache is adapter-agnostic. Pass your adapter to the supervisor:

      children = [
        {SchemaCache.Supervisor, adapter: SchemaCache.Adapters.ETS}
      ]

  Any module implementing `SchemaCache.Adapter` can be used. Modules
  built with [ElixirCache](https://github.com/MikaAK/elixir_cache)
  (`use Cache`) are detected automatically and work without a wrapper.
  See `SchemaCache.Adapter` for details.

  ## TTL

  TTL is passed through to the adapter. If your backend supports TTL,
  it will be used. If not, it is ignored. SchemaCache does not implement
  its own TTL mechanism.

  ## Cache-Aside

  On a cache miss, SchemaCache calls your function to fetch from the
  source and caches the result:

      SchemaCache.read("find_user", %{id: 5}, :timer.minutes(15), fn ->
        MyApp.Users.find(%{id: 5})
      end)

  On a cache hit, the stored value is returned without invoking the
  callback. On a miss, the callback is invoked, the result is cached,
  and schema key references are recorded for SMKES.

  ## Write-Through

  When your application can't serve stale results, write-through
  updates cached values in place after mutations:

      SchemaCache.update(
        fn -> MyApp.Users.update_user(user, params) end,
        strategy: :write_through
      )

  For singular cache entries, the value is replaced directly. For
  collections (keys prefixed with `all_`), SchemaCache locates the
  item within the list by primary key and replaces it in place.

  ## Key Conventions

  When caching a collection, prefix the key with `all_`. This convention
  is required for write-through to correctly identify and update
  collections in the cache.

      SchemaCache.read("all_users", params, ttl, fn -> MyApp.Users.all(params) end)
      SchemaCache.read("find_user", params, ttl, fn -> MyApp.Users.find(params) end)
  """

  require Logger

  alias SchemaCache.Adapter
  alias SchemaCache.KeyGenerator
  alias SchemaCache.KeyRegistry

  @async_threshold 100

  # --- Internal helpers ---

  defp set_key(key), do: "__set:#{key}"

  defp adapter do
    with nil <- :persistent_term.get(:schema_cache_adapter, nil) do
      raise """
      SchemaCache adapter not configured.
      Start SchemaCache.Supervisor with adapter: YourAdapter
      """
    end
  end

  defp maybe_async_each(collection, fun) do
    if exceeds_threshold?(collection, @async_threshold) do
      collection
      |> Task.async_stream(fun)
      |> Stream.run()
    else
      Enum.each(collection, fun)
    end
  end

  defp exceeds_threshold?([], _n), do: false
  defp exceeds_threshold?(_list, n) when n <= 0, do: true
  defp exceeds_threshold?([_ | rest], n), do: exceeds_threshold?(rest, n - 1)

  # --- Public API ---

  @doc """
  Executes a create callback and evicts all cached collections for the schema type.

  The callback function must return `{:ok, schema}` on success. Any other
  return value passes through without triggering cache operations.

  ## Examples

      SchemaCache.create(fn ->
        %User{}
        |> User.changeset(params)
        |> Repo.insert()
      end)
  """
  @spec create(function()) :: {:ok, struct()} | {:error, any()}
  def create(fnc) do
    with {:ok, schema} <- fnc.() do
      schema
      |> tap(&flush(&1, :new_schema))
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Executes an update callback and handles cache invalidation.

  By default, evicts all cache keys referencing the schema instance.
  Pass `strategy: :write_through` to update cached values in place.

  ## Options

    * `:strategy` - Defines the cache update strategy:
      * `:evict` - Evicts all cache keys referencing the mutated schema
        instance. **(default)**
      * `:write_through` - Updates all cached values referencing the schema
        in place, including both singular entries and items within collections.
        Collection updates are not atomic (see `write_to_cache/2`).

    * `:ttl` - TTL to pass through to the adapter when using `:write_through`.
      Ignored for other strategies.

  ## Examples

      # Update with default eviction
      SchemaCache.update(fn -> Actions.update(User, user, params) end)

      # Update with write-through
      SchemaCache.update(
        fn -> Actions.update(User, user, params) end,
        strategy: :write_through
      )
  """
  @spec update(function(), keyword()) :: {:ok, struct()} | {:error, any()}
  def update(fnc, opts \\ []) do
    case Keyword.get(opts, :strategy, :evict) do
      :evict -> do_evict_keys(fnc)
      :write_through -> do_write_through(fnc, opts)
    end
  end

  @doc """
  Executes a delete callback and evicts all cache keys referencing the schema.

  The callback function must return `{:ok, schema}` on success. Any other
  return value passes through without triggering cache operations.

  ## Examples

      SchemaCache.delete(fn -> Repo.delete(user) end)
  """
  @spec delete(function()) :: {:ok, struct()} | {:error, any()}
  def delete(fnc) do
    with {:ok, schema} <- fnc.() do
      schema
      |> tap(&flush/1)
      |> then(&{:ok, &1})
    end
  end

  defp do_evict_keys(fnc) do
    with {:ok, schema} <- fnc.() do
      schema
      |> tap(&flush/1)
      |> then(&{:ok, &1})
    end
  end

  defp do_write_through(fnc, opts) do
    with {:ok, schema} <- fnc.() do
      schema
      |> tap(&write_to_cache(&1, Keyword.get(opts, :ttl)))
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Directly updates all cached values that reference the given schema.

  Unlike `update/2`, this function does not invoke a callback or perform
  any database operation. It simply pushes the given struct into every
  cache entry that references it, using the same write-through logic as
  `update/2` with `strategy: :write_through`.

  Useful when a virtual field or computed attribute changes and only the
  cache needs updating, without a database write.

  **Note:** write-through updates to collection cache entries are not
  atomic. Between reading and writing the collection, another process
  could modify it. This is a best-effort optimization; the next `read/4`
  cache miss will always fetch the correct state from the source.

  ## Examples

      # Update the cache after computing a virtual field
      user = %{user | online_status: :active}
      :ok = SchemaCache.write_to_cache(user)

      # With explicit TTL
      :ok = SchemaCache.write_to_cache(user, :timer.minutes(15))
  """
  @spec write_to_cache(struct(), any()) :: :ok
  def write_to_cache(schema, ttl \\ nil) do
    set_k =
      schema
      |> KeyGenerator.schema_cache_key()
      |> set_key()

    a = adapter()

    case Adapter.smembers(a, set_k) do
      {:ok, ids} when is_list(ids) ->
        do_write_through_refs(a, set_k, ids, ttl, schema)

      _ ->
        :ok
    end
  end

  defp do_write_through_refs(a, set_k, ids, ttl, schema) do
    resolved = KeyRegistry.resolve(ids)

    clean_unresolved_ids(a, set_k, ids, resolved)

    cache_keys = Enum.map(resolved, &elem(&1, 1))

    case Adapter.mget(a, cache_keys) do
      {:ok, values} ->
        {live, stale} =
          resolved
          |> Enum.zip(values)
          |> Enum.split_with(fn {_, val} -> val != nil end)

        Enum.each(stale, fn {{id, _key}, _} ->
          Adapter.srem(a, set_k, id)
          KeyRegistry.unregister_id(id)
        end)

        live
        |> Enum.map(fn {{_id, key_ref}, _} -> key_ref end)
        |> maybe_async_each(&update_key_ref(&1, ttl, schema))

      {:error, reason} ->
        Logger.warning("[SchemaCache] write-through mget failed: #{inspect(reason)}")
        :ok
    end
  end

  defp update_key_ref(key_ref, ttl, value) do
    case Adapter.get(adapter(), key_ref) do
      {:ok, nil} ->
        :ok

      {:ok, cached} when is_list(cached) ->
        maybe_update_cached_collection(cached, key_ref, ttl, value)

      {:ok, _singular} ->
        Adapter.put(adapter(), key_ref, value, ttl)
    end
  end

  defp maybe_update_cached_collection(
         cached_collection,
         key_ref,
         ttl,
         %schema{} = value
       ) do
    schema.__schema__(:primary_key)
    |> Enum.reduce(
      %{},
      &Map.put(&2, &1, Map.get(value, &1))
    )
    |> then(
      &Enum.find_index(
        cached_collection,
        fn el -> match_schema_by_primary_keys(el, &1) end
      )
    )
    |> case do
      nil ->
        :ok

      idx ->
        cached_collection
        |> List.replace_at(idx, value)
        |> then(&Adapter.put(adapter(), key_ref, &1, ttl))
    end
  end

  defp match_schema_by_primary_keys(collection_elem, pks_sig) do
    Enum.all?(pks_sig, fn {k, v} ->
      Map.get(collection_elem, k) === v
    end)
  end

  # --- Read ---

  @doc """
  Reads a value from the cache, falling back to the source on a miss.

  On a cache hit, the stored value is returned immediately. On a miss,
  the callback is invoked, the result is cached, and SMKES key references
  are recorded so that future mutations can evict or update this entry.

  The cache key is built from `key` and `params` using
  `SchemaCache.KeyGenerator.cache_key/2`. Two calls with the same `key`
  and `params` will resolve to the same cache entry.

  ## Arguments

    * `key` - A string prefix identifying the query (e.g. `"users"`,
      `"jobs"`). Combined with `params` to form the full cache key.
    * `params` - A map of query parameters. Combined with `key` to form
      the full cache key.
    * `ttl` - Time-to-live passed through to the adapter. Pass `nil` to
      cache without expiry (adapter-dependent).
    * `fnc` - A zero-arity function that fetches the value from the source.
      Should return `{:ok, struct}` for singular results or a list for
      collections.

  ## Return Values

    * `{:ok, value}`: cache hit for a singular value, or freshly fetched
      and cached singular value.
    * `list`: cache hit for a collection, or freshly fetched and cached
      collection.
    * `[]`: empty list results are **not cached** and pass through directly.
    * `{:error, reason}`: error results from the callback pass through
      without being cached.

  ## Examples

      # Singular record
      {:ok, user} =
        SchemaCache.read("users", %{id: 5}, :timer.minutes(15), fn ->
          MyApp.Users.find(%{id: 5})
        end)

      # Collection
      users =
        SchemaCache.read("users", %{active: true}, :timer.minutes(5), fn ->
          MyApp.Users.all(%{active: true})
        end)
  """
  @spec read(binary(), map(), nil | pos_integer(), function()) :: any()
  def read(key, params, ttl \\ nil, fnc) do
    cache_key = KeyGenerator.cache_key(key, params)

    case Adapter.get(adapter(), cache_key) do
      {:ok, nil} ->
        get_set_value(cache_key, ttl, fnc)

      {:ok, val} when is_list(val) ->
        val

      {:ok, val} ->
        {:ok, val}

      error ->
        fetch_from_source(fnc, error)
    end
  end

  defp get_set_value(cache_key, ttl, fnc) do
    case fnc.() do
      {:ok, value} ->
        Adapter.put(adapter(), cache_key, value, ttl)
        associate_key_reference_with_schema(cache_key, value)
        {:ok, value}

      [] ->
        []

      value when is_list(value) ->
        Adapter.put(adapter(), cache_key, value, ttl)
        associate_key_reference_with_schema(cache_key, value)
        associate_key_reference_with_schema_type(cache_key, value)
        value

      res ->
        res
    end
  end

  defp fetch_from_source(fnc, error) do
    Logger.error("""
    [SchemaCache] Unable to fetch from cache, falling back to source.
    Error: #{inspect(error)}
    """)

    fnc.()
  end

  # --- Flush / eviction ---

  @doc """
  Evicts cached query results using SMKES.

  This is the low-level eviction function used internally by `update/2`
  and `delete/1`. You can call it directly when you need to invalidate
  cache entries for a schema without performing a mutation through
  SchemaCache.

  ## Behaviors

    * `flush(schema)`: evicts all cache keys referencing the specific
      schema instance, identified by its module and primary key values.
    * `flush(schema, :new_schema)`: evicts all cached collections for
      the schema's module type. Use when a new record has been created
      outside of `create/1`.

  ## Examples

      # Evict all cache entries referencing a specific user
      :ok = SchemaCache.flush(user)

      # Evict all cached User collections (e.g. after an external insert)
      :ok = SchemaCache.flush(user, :new_schema)
  """
  @spec flush(struct(), nil | atom()) :: :ok
  def flush(schema, opts \\ nil)

  def flush(%schema_type{} = _schema, :new_schema) do
    evict_reference_keys("#{schema_type}")
  end

  def flush(%_{} = schema, _opts) do
    schema
    |> KeyGenerator.schema_cache_key()
    |> evict_reference_keys()
  end

  defp evict_reference_keys(key) do
    set_k = set_key(key)
    a = adapter()

    case Adapter.smembers(a, set_k) do
      {:ok, ids} when is_list(ids) ->
        do_evict_resolved(a, set_k, ids)

      _ ->
        :ok
    end
  end

  defp do_evict_resolved(a, set_k, ids) do
    resolved = KeyRegistry.resolve(ids)

    clean_unresolved_ids(a, set_k, ids, resolved)

    cache_keys = Enum.map(resolved, &elem(&1, 1))

    case Adapter.mget(a, cache_keys) do
      {:ok, values} ->
        {live, stale} =
          resolved
          |> Enum.zip(values)
          |> Enum.split_with(fn {_, val} -> val != nil end)

        Enum.each(stale, fn {{id, _key}, _} ->
          Adapter.srem(a, set_k, id)
          KeyRegistry.unregister_id(id)
        end)

        maybe_async_each(live, fn {{id, key_ref}, _} ->
          Adapter.delete(a, key_ref)
          Adapter.srem(a, set_k, id)
          KeyRegistry.unregister_id(id)
        end)

      {:error, reason} ->
        Logger.warning("[SchemaCache] eviction mget failed: #{inspect(reason)}")
        :ok
    end
  end

  defp clean_unresolved_ids(a, set_k, ids, resolved) do
    resolved_ids = MapSet.new(resolved, &elem(&1, 0))

    ids
    |> Enum.reject(&MapSet.member?(resolved_ids, &1))
    |> Enum.each(&Adapter.srem(a, set_k, &1))
  end

  # --- Key reference association ---

  defp associate_key_reference_with_schema_type(
         cache_key,
         [%resource_type{} | _] = value
       )
       when is_list(value) do
    cache_key
    |> KeyRegistry.register()
    |> then(
      &Adapter.sadd(
        adapter(),
        set_key("#{resource_type}"),
        &1
      )
    )
  end

  defp associate_key_reference_with_schema_type(_cache_key, _value), do: :ok

  defp associate_key_reference_with_schema(cache_key, value) when is_list(value) do
    maybe_async_each(value, &associate_key_reference_with_schema(cache_key, &1))
  end

  defp associate_key_reference_with_schema(cache_key, %_{} = value) do
    value
    |> KeyGenerator.schema_cache_key()
    |> set_key()
    |> then(&Adapter.sadd(adapter(), &1, KeyRegistry.register(cache_key)))
  end

  defp associate_key_reference_with_schema(_, _), do: :ok
end
