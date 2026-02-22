defmodule SchemaCache.Test.FakeSchema do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "fake_schemas" do
    field(:name, :string)
    field(:email, :string)
  end
end
