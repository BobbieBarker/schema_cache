ExUnit.start()

{:ok, _} = SchemaCache.Supervisor.start_link(adapter: SchemaCache.Adapters.ETS)

# Initialize ETS tables from the test runner process so they persist
# for the entire test suite (table ownership is tied to the creating process).
SchemaCache.Adapters.ETS.get("__init__")
SchemaCache.Adapters.ETS.sadd("__init__", "__init__")

{:ok, _} = SchemaCache.Test.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(SchemaCache.Test.Repo, :manual)

# Start the ElixirCache ETS module so its table exists for the entire test run.
{:ok, _} =
  Supervisor.start_link(
    [SchemaCache.Test.ElixirCacheETS],
    strategy: :one_for_one
  )

# Redis connections are started per-test in RedisCase, not globally.
# This provides better isolation. Each test gets its own connection
# and a fresh FLUSHDB before running.
