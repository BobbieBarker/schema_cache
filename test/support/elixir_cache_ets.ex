defmodule SchemaCache.Test.ElixirCacheETS do
  @moduledoc false

  use Cache,
    adapter: Cache.ETS,
    name: :schema_cache_test_ec_ets,
    opts: []
end
