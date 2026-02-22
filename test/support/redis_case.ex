defmodule SchemaCache.Test.RedisCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SchemaCache.Test.User
    end
  end

  setup do
    redis_url = Application.get_env(:schema_cache, :redis_url, "redis://localhost:6379")
    {:ok, conn} = Redix.start_link(redis_url)

    # Flush Redis before each test
    {:ok, "OK"} = Redix.command(conn, ["FLUSHDB"])

    # Make connection available to the adapter
    Process.put(:schema_cache_redis_conn, conn)

    # Set the adapter to Redis for this test
    Application.put_env(:schema_cache, :adapter, SchemaCache.Test.RedisAdapter)

    on_exit(fn ->
      # Reset adapter back to ETS
      Application.put_env(:schema_cache, :adapter, SchemaCache.Adapters.ETS)

      # Stop the connection
      if Process.alive?(conn), do: GenServer.stop(conn)
    end)

    %{redis_conn: conn}
  end
end
