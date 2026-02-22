defmodule SchemaCache.Test.FakeCompositeSchema do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "fake_composite_schemas" do
    field(:tenant_id, :integer, primary_key: true)
    field(:resource_id, :integer, primary_key: true)
    field(:label, :string)
  end
end
