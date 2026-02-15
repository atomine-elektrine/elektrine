defmodule Elektrine.Email.PgpKeyCache do
  @moduledoc """
  Schema for caching PGP public key lookups from WKD and keyservers.
  Avoids repeated network requests for the same email addresses.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "pgp_key_cache" do
    field :email, :string
    # ASCII-armored PGP public key
    field :public_key, :string
    # Short key ID (last 8 hex chars)
    field :key_id, :string
    # Full 40-char fingerprint
    field :fingerprint, :string
    # "wkd", "keyserver", "dns"
    field :source, :string
    # "found", "not_found", "error"
    field :status, :string, default: "found"
    field :expires_at, :utc_datetime

    timestamps()
  end

  @doc """
  Changeset for creating/updating a cache entry.
  """
  def changeset(cache_entry, attrs) do
    cache_entry
    |> cast(attrs, [:email, :public_key, :key_id, :fingerprint, :source, :status, :expires_at])
    |> validate_required([:email, :status])
    |> validate_inclusion(:status, ["found", "not_found", "error"])
    |> validate_inclusion(:source, ["wkd", "keyserver", "dns", nil])
    |> unique_constraint(:email)
    |> downcase_email()
  end

  defp downcase_email(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email, String.downcase(email))
    end
  end
end
