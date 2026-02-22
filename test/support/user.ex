defmodule SchemaCache.Test.User do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @required [:name, :email]
  @allowed [:name, :email]

  schema "users" do
    field(:name, :string)
    field(:email, :string)

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, @allowed)
    |> validate_required(@required)
    |> unique_constraint(:email)
  end
end
