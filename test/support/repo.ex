defmodule SchemaCache.Test.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :schema_cache,
    adapter: Ecto.Adapters.Postgres
end
