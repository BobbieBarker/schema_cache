defmodule SchemaCache.Test.ElixirCacheRedis do
  @moduledoc false

  use Cache,
    adapter: Cache.Redis,
    name: :schema_cache_test_ec_redis,
    opts: {:schema_cache, :test_elixir_cache_redis_opts}
end
