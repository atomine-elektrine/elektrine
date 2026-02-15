defmodule Elektrine.Accounts.AppPassword do
  @moduledoc """
  Schema for app-specific passwords that bypass 2FA for email clients.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_passwords" do
    field :name, :string
    field :token_hash, :string
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    field :expires_at, :utc_datetime

    # Virtual field for the raw token (only available on creation)
    field :token, :string, virtual: true

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(app_password, attrs) do
    app_password
    |> cast(attrs, [:name, :token_hash, :user_id, :expires_at])
    |> validate_required([:name, :token_hash, :user_id])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Creates a changeset for a new app password with a generated token.
  """
  def create_changeset(attrs) do
    # Generate a secure random token
    token = generate_token()
    # Hash the token WITHOUT dashes for storage
    clean_token = String.replace(token, "-", "")
    token_hash = hash_token(clean_token)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:name, :user_id, :expires_at])
      |> validate_required([:name, :user_id])
      |> validate_length(:name, max: 100)
      |> put_change(:token_hash, token_hash)

    # Attach the raw token (WITH dashes) to the struct for display to the user
    # This is the only time the raw token is available
    %{changeset | changes: Map.put(changeset.changes, :token, token)}
  end

  @doc """
  Updates last used information for an app password.
  """
  def update_last_used(app_password, ip_address \\ nil) do
    app_password
    |> change(%{
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_used_ip: ip_address
    })
  end

  @doc """
  Generates a secure random token for app password.
  Format: xxxx-xxxx-xxxx-xxxx (16 characters)
  """
  def generate_token do
    :crypto.strong_rand_bytes(12)
    |> Base.encode32(case: :lower, padding: false)
    |> String.slice(0, 16)
    |> format_token()
  end

  defp format_token(token) do
    token
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  @doc """
  Hashes a token for secure storage.
  """
  def hash_token(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies if a given token matches the stored hash.
  """
  def verify_token(token, token_hash) do
    hash_token(token) == token_hash
  end
end
