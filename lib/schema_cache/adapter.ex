defmodule SchemaCache.Adapter do
  @moduledoc """
  Behaviour for cache adapter implementations.

  SchemaCache is adapter-agnostic. Any module implementing this behaviour
  can serve as the cache backend: Nebulex, ConCache, Cachex, Redis, ETS, etc.

  ## ElixirCache Integration

  Modules created with `use Cache` from
  [ElixirCache](https://github.com/MikaAK/elixir_cache) are detected
  automatically and work without a wrapper module. Just pass the module
  directly:

      children = [
        MyApp.Cache,
        {SchemaCache.Supervisor, adapter: MyApp.Cache}
      ]

  For Redis-backed ElixirCache modules, SchemaCache also auto-detects
  native set operations via `command/1`, giving you full SMKES performance
  with zero configuration.

  ## Custom Adapters

  Implement three required callbacks: `get/1`, `put/3`, and `delete/1`.
  SchemaCache builds its key reference tracking (SMKES) on top of these
  primitives.

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
    if function_exported?(adapter, :init, 0),
      do: adapter.init(),
      else: :ok
  end

  @doc false
  def resolve_capabilities(adapter) do
    Code.ensure_loaded(adapter)
    elixir_cache? = elixir_cache?(adapter)
    redis_backed? = elixir_cache? and detect_redis(adapter)

    :persistent_term.put(:schema_cache_adapter_caps, %{
      # ElixirCache modules export sadd/2 etc. with incompatible signatures
      # (key prefixing, TermEncoder encoding, different return values).
      # Only mark as native for non-ElixirCache adapters.
      native_sadd: not elixir_cache? and function_exported?(adapter, :sadd, 2),
      native_srem: not elixir_cache? and function_exported?(adapter, :srem, 2),
      native_smembers: not elixir_cache? and function_exported?(adapter, :smembers, 1),
      native_mget: not elixir_cache? and function_exported?(adapter, :mget, 1),
      elixir_cache: elixir_cache?,
      redis_backed: redis_backed?
    })
  end

  defp elixir_cache?(adapter) do
    with true <- function_exported?(adapter, :cache_adapter, 0),
         mod = adapter.cache_adapter(),
         {:module, ^mod} <- Code.ensure_loaded(mod) do
      Cache in (mod.__info__(:attributes)[:behaviour] || [])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp detect_redis(adapter) do
    function_exported?(adapter, :command, 1) and
      adapter.cache_adapter() == Cache.Redis
  rescue
    _ -> false
  end

  # --- Runtime dispatch: core operations ---

  @doc false
  def get(adapter, key), do: adapter.get(key)

  @doc false
  def put(adapter, key, value, ttl) do
    if capability(:elixir_cache),
      do: elixir_cache_put(adapter, key, value, ttl),
      else: adapter.put(key, value, ttl: ttl)
  end

  @doc false
  def put_no_ttl(adapter, key, value) do
    if capability(:elixir_cache),
      do: adapter.put(key, value),
      else: adapter.put(key, value, [])
  end

  @doc false
  def delete(adapter, key), do: adapter.delete(key)

  defp elixir_cache_put(adapter, key, value, nil), do: adapter.put(key, value)
  defp elixir_cache_put(adapter, key, value, ttl), do: adapter.put(key, ttl, value)

  # --- Runtime dispatch: set operations ---

  @doc false
  def sadd(adapter, key, member) do
    cond do
      capability(:native_sadd) -> adapter.sadd(key, member)
      capability(:redis_backed) -> redis_sadd(adapter, key, member)
      true -> SchemaCache.SetLock.sadd(key, member, adapter)
    end
  end

  @doc false
  def srem(adapter, key, member) do
    cond do
      capability(:native_srem) -> adapter.srem(key, member)
      capability(:redis_backed) -> redis_srem(adapter, key, member)
      true -> SchemaCache.SetLock.srem(key, member, adapter)
    end
  end

  @doc false
  def smembers(adapter, key) do
    cond do
      capability(:native_smembers) -> adapter.smembers(key)
      capability(:redis_backed) -> redis_smembers(adapter, key)
      true -> SchemaCache.SetLock.smembers(key, adapter)
    end
  end

  @doc false
  def mget(adapter, keys) do
    # No redis_backed path. ElixirCache's key prefixing and TermEncoder
    # encoding make raw MGET via command/1 unreliable. SetLock uses
    # individual adapter.get/1 calls which handle both correctly.
    if capability(:native_mget),
      do: adapter.mget(keys),
      else: SchemaCache.SetLock.mget(keys, adapter)
  end

  # --- ElixirCache Redis command helpers ---

  defp redis_sadd(adapter, key, member) do
    with {:ok, _} <- adapter.command(["SADD", key, to_string(member)]), do: :ok
  end

  defp redis_srem(adapter, key, member) do
    with {:ok, _} <- adapter.command(["SREM", key, to_string(member)]), do: :ok
  end

  defp redis_smembers(adapter, key) do
    case adapter.command(["SMEMBERS", key]) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, members} ->
        members
        |> Enum.map(&String.to_integer/1)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capability(name) do
    :persistent_term.get(:schema_cache_adapter_caps)[name]
  end
end
