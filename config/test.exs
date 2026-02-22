import Config

config :schema_cache, SchemaCache.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "schema_cache_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :schema_cache,
  ecto_repos: [SchemaCache.Test.Repo],
  adapter: SchemaCache.Adapters.ETS

config :schema_cache, :redis_url, "redis://localhost:6379"

config :logger, level: :warning
