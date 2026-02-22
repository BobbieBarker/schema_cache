defmodule SchemaCache.Test.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias SchemaCache.Adapters.ETS
  alias SchemaCache.Test.Repo

  using do
    quote do
      alias SchemaCache.Test.Repo
      alias SchemaCache.Test.User
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Repo)

    unless tags[:async] do
      Sandbox.mode(Repo, {:shared, self()})
    end

    for table <- ETS.managed_tables() do
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end

    :ok
  end
end
