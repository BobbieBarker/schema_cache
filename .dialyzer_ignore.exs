[
  # ElixirCache `use Cache` macro generates code with unreachable pattern matches.
  # These are test-only support modules and not under our control.
  {"test/support/elixir_cache_ets.ex", :pattern_match},
  {"test/support/elixir_cache_redis.ex", :pattern_match_cov}
]
