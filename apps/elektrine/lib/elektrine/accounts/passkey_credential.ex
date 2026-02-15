defmodule Elektrine.Accounts.PasskeyCredential do
  @moduledoc """
  Schema for WebAuthn/Passkey credentials.

  Users can register up to 10 passkeys across multiple devices (phone, laptop, security key).
  Passkeys provide passwordless, phishing-resistant authentication.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_passkeys_per_user 10

  schema "passkey_credentials" do
    belongs_to :user, Elektrine.Accounts.User

    # WebAuthn credential ID (raw bytes from authenticator)
    field :credential_id, :binary
    # Public key in COSE format (stored as binary via :erlang.term_to_binary)
    field :public_key, :binary
    # Counter for clone detection - increments with each use
    field :sign_count, :integer, default: 0
    # Stable random bytes for resident/discoverable credentials
    field :user_handle, :binary
    # User-friendly name (e.g., "MacBook", "iPhone", "YubiKey")
    field :name, :string, default: "Passkey"
    # Authenticator type identifier (AAGUID from attestation)
    field :aaguid, :binary
    # Transport hints: ["usb", "nfc", "ble", "internal", "hybrid"]
    field :transports, {:array, :string}, default: []
    field :last_used_at, :utc_datetime
    # Audit information
    field :created_from_ip, :string
    field :created_user_agent, :string

    timestamps()
  end

  @doc "Maximum number of passkeys allowed per user"
  def max_passkeys_per_user, do: @max_passkeys_per_user

  @doc "Generate a cryptographically random user handle (32 bytes)"
  def generate_user_handle do
    :crypto.strong_rand_bytes(32)
  end

  @doc "Changeset for creating a new passkey credential"
  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :user_id,
      :credential_id,
      :public_key,
      :sign_count,
      :user_handle,
      :name,
      :aaguid,
      :transports,
      :created_from_ip,
      :created_user_agent
    ])
    |> validate_required([:user_id, :credential_id, :public_key, :user_handle])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for updating sign count after authentication"
  def update_sign_count_changeset(credential, sign_count) do
    credential
    |> change()
    |> put_change(:sign_count, sign_count)
    |> put_change(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Changeset for renaming a passkey"
  def rename_changeset(credential, name) do
    credential
    |> change()
    |> put_change(:name, name)
    |> validate_length(:name, max: 100)
  end
end
