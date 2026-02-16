defmodule Elektrine.Auth.APITokenRevocation do
  @moduledoc """
  Stores revoked mobile/API bearer tokens until their natural expiration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "api_token_revocations" do
    field :token_hash, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [:token_hash, :expires_at, :revoked_at])
    |> validate_required([:token_hash, :expires_at, :revoked_at])
    |> unique_constraint(:token_hash)
  end
end
