defmodule Elektrine.OIDC.SigningKey do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo

  schema "oidc_signing_keys" do
    field(:kid, :string)
    field(:alg, :string, default: "RS256")
    field(:public_key_pem, :string)
    field(:private_key_pem, :string)
    field(:active, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(signing_key, attrs) do
    signing_key
    |> cast(attrs, [:kid, :alg, :public_key_pem, :private_key_pem, :active])
    |> validate_required([:kid, :alg, :public_key_pem, :private_key_pem, :active])
    |> unique_constraint(:kid)
  end

  def current do
    from(k in __MODULE__, where: k.active == true, order_by: [desc: k.inserted_at], limit: 1)
    |> Repo.one()
  end

  def create!(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert!()
  end
end
