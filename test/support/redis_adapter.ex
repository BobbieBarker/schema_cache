defmodule SchemaCache.Test.RedisAdapter do
  @moduledoc false

  @behaviour SchemaCache.Adapter

  # Uses a Redix connection stored in the process dictionary.
  # The connection is started in RedisCase setup, per-test.

  @impl true
  def get(key) do
    case Redix.command(redis_conn(), ["GET", key]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, :erlang.binary_to_term(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(key, value, opts) do
    encoded = :erlang.term_to_binary(value)

    command =
      if Keyword.get(opts, :ttl) do
        ["SET", key, encoded, "PX", to_string(Keyword.get(opts, :ttl))]
      else
        ["SET", key, encoded]
      end

    case Redix.command(redis_conn(), command) do
      {:ok, "OK"} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case Redix.command(redis_conn(), ["DEL", key]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Native set operations using Redis SADD/SREM/SMEMBERS.
  # Members are integer IDs from KeyRegistry, stored as strings in Redis.

  @impl true
  def sadd(key, member) do
    case Redix.command(redis_conn(), ["SADD", key, to_string(member)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def srem(key, member) do
    case Redix.command(redis_conn(), ["SREM", key, to_string(member)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def smembers(key) do
    case Redix.command(redis_conn(), ["SMEMBERS", key]) do
      {:ok, []} -> {:ok, nil}
      {:ok, members} -> {:ok, Enum.map(members, &String.to_integer/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def mget(keys) do
    case Redix.command(redis_conn(), ["MGET" | keys]) do
      {:ok, values} ->
        values
        |> Enum.map(fn
          nil -> nil
          binary -> :erlang.binary_to_term(binary)
        end)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redis_conn do
    Process.get(:schema_cache_redis_conn) ||
      raise "Redis connection not set. Call Process.put(:schema_cache_redis_conn, conn) in test setup."
  end
end
