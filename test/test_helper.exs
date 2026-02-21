ExUnit.start()

{:ok, _} = SchemaCache.Supervisor.start_link(adapter: SchemaCache.Adapters.ETS)

# Initialize ETS tables from the test runner process so they persist
# for the entire test suite (table ownership is tied to the creating process).
SchemaCache.Adapters.ETS.get("__init__")
SchemaCache.Adapters.ETS.sadd("__init__", "__init__")

{:ok, _} = SchemaCache.Test.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(SchemaCache.Test.Repo, :manual)

# Redis connections are started per-test in RedisCase, not globally.
# This provides better isolation — each test gets its own connection
# and a fresh FLUSHDB before running.
