import Config

config :schema_cache, adapter: SchemaCache.Adapters.ETS

import_config "#{config_env()}.exs"
