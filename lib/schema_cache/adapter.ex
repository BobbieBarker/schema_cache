defmodule SchemaCache.Adapter do
  @moduledoc """
  Behaviour for cache adapter implementations.

  SchemaCache is adapter-agnostic. Implement this behaviour to plug in
  any caching backend: Nebulex, ConCache, Cachex, Redis, ETS, etc.

  The behaviour requires three core operations: `get/1`, `put/3`, and
  `delete/1`. SchemaCache builds its key reference tracking (SMKES) on
  top of these primitives.

  Adapters can optionally implement `init/0`, `sadd/2`, `srem/2`,
  `smembers/1`, and `mget/1`. `init/0` is called by
  `SchemaCache.Supervisor` during startup, giving adapters a chance to
  create tables, open connections, or perform other setup. Adapters with
  native set operations (e.g., Redis SADD/SREM) should implement `sadd/2`,
  `srem/2`, and `smembers/1` to avoid the partitioned lock fallback that
  SchemaCache uses for adapters without them. The fallback is correct but
  slower.

  ## Return Conventions

    * `get/1` must return `{:ok, value}` on a hit, `{:ok, nil}` on a
      miss, or `{:error, reason}` on failure. SchemaCache falls back to
      the source function when it receives an error tuple.
    * `put/3` must return `:ok` or `{:error, reason}`.
    * `delete/1` must return `:ok` or `{:error, reason}`.

  ## TTL

  TTL is passed as a `:ttl` option in the `opts` keyword list of `put/3`.
  If your backend supports TTL, extract it with `Keyword.get(opts, :ttl)`
  and use it. If not, ignore it. SchemaCache does not implement its own
  TTL mechanism.

  ## Configuration

  Set the adapter in your application config:

      config :schema_cache, adapter: MyApp.SchemaCacheAdapter

  ## Example: Nebulex Adapter

      defmodule MyApp.SchemaCacheAdapter do
        @behaviour SchemaCache.Adapter

        @impl true
        def get(key) do
          case MyApp.Cache.get(key) do
            nil -> {:ok, nil}
            value -> {:ok, value}
          end
        end

        @impl true
        def put(key, value, opts) do
          MyApp.Cache.put(key, value, opts)
          :ok
        end

        @impl true
        def delete(key) do
          MyApp.Cache.delete(key)
          :ok
        end
      end

  ## Example: Cachex Adapter

      defmodule MyApp.CachexAdapter do
        @behaviour SchemaCache.Adapter

        @impl true
        def get(key) do
          case Cachex.get(:my_cache, key) do
            {:ok, nil} -> {:ok, nil}
            {:ok, value} -> {:ok, value}
            {:error, _} = err -> err
          end
        end

        @impl true
        def put(key, value, opts) do
          ttl = Keyword.get(opts, :ttl)
          Cachex.put(:my_cache, key, value, ttl: ttl)
          :ok
        end

        @impl true
        def delete(key) do
          Cachex.del(:my_cache, key)
          :ok
        end
      end
  """

  @doc """
  Fetches a value by key.

  Returns `{:ok, value}` on a cache hit, `{:ok, nil}` on a cache miss,
  or `{:error, reason}` if the backend is unavailable. When SchemaCache
  receives an error tuple, it logs a warning and falls back to the source
  function.
  """
  @callback get(key :: String.t()) :: {:ok, any()} | {:error, any()}

  @doc """
  Stores a value at the given key.

  The `opts` keyword list may include `:ttl` (time-to-live in
  milliseconds). If your backend supports TTL, use it. If not, ignore it.
  """
  @callback put(key :: String.t(), value :: any(), opts :: keyword()) :: :ok | {:error, any()}

  @doc """
  Deletes a key from the cache.

  Called during SMKES eviction to remove cached query results that
  reference a mutated schema. Should return `:ok` even if the key
  does not exist.
  """
  @callback delete(key :: String.t()) :: :ok | {:error, any()}

  @doc """
  Optional initialization callback invoked by `SchemaCache.Supervisor`
  at startup.

  Use this to create ETS tables, open connections, or perform other setup
  that should happen once when the application starts. Must be idempotent
  to handle supervisor restarts gracefully.
  """
  @callback init() :: :ok

  @doc "Atomically adds a member to a set identified by key."
  @callback sadd(key :: String.t(), member :: term()) :: :ok | {:error, any()}

  @doc "Atomically removes a member from a set identified by key."
  @callback srem(key :: String.t(), member :: term()) :: :ok | {:error, any()}

  @doc "Returns all members of a set."
  @callback smembers(key :: String.t()) :: {:ok, list() | nil} | {:error, any()}

  @doc "Fetches multiple keys in a single operation."
  @callback mget(keys :: [String.t()]) :: {:ok, [any() | nil]} | {:error, any()}

  @optional_callbacks [init: 0, sadd: 2, srem: 2, smembers: 1, mget: 1]

  # --- Boot-time setup ---

  @doc false
  def init(adapter) do
    if function_exported?(adapter, :init, 0) do
      adapter.init()
    else
      :ok
    end
  end

  @doc false
  def resolve_capabilities(adapter) do
    :persistent_term.put(:schema_cache_adapter_caps, %{
      sadd: function_exported?(adapter, :sadd, 2),
      srem: function_exported?(adapter, :srem, 2),
      smembers: function_exported?(adapter, :smembers, 1),
      mget: function_exported?(adapter, :mget, 1)
    })
  end

  # --- Runtime dispatch ---

  @doc false
  def sadd(adapter, key, member) do
    if capability(:sadd) do
      adapter.sadd(key, member)
    else
      SchemaCache.SetLock.sadd(key, member, adapter)
    end
  end

  @doc false
  def srem(adapter, key, member) do
    if capability(:srem) do
      adapter.srem(key, member)
    else
      SchemaCache.SetLock.srem(key, member, adapter)
    end
  end

  @doc false
  def smembers(adapter, key) do
    if capability(:smembers) do
      adapter.smembers(key)
    else
      SchemaCache.SetLock.smembers(key, adapter)
    end
  end

  @doc false
  def mget(adapter, keys) do
    if capability(:mget) do
      adapter.mget(keys)
    else
      SchemaCache.SetLock.mget(keys, adapter)
    end
  end

  defp capability(name) do
    :persistent_term.get(:schema_cache_adapter_caps)[name]
  end
end
