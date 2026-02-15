defmodule Elektrine.Repo.Migrations.CreatePasskeyCredentials do
  use Ecto.Migration

  def change do
    create table(:passkey_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # WebAuthn credential ID (raw bytes)
      add :credential_id, :binary, null: false
      # Public key in COSE format (stored as term_to_binary)
      add :public_key, :binary, null: false
      # Counter for clone detection
      add :sign_count, :integer, default: 0, null: false
      # Stable random bytes per user for resident credentials
      add :user_handle, :binary, null: false
      # User-friendly name for the passkey
      add :name, :string, default: "Passkey"
      # Authenticator type identifier (AAGUID)
      add :aaguid, :binary
      # Transport hints: usb, nfc, ble, internal, hybrid
      add :transports, {:array, :string}, default: []
      add :last_used_at, :utc_datetime
      # Metadata for auditing
      add :created_from_ip, :string
      add :created_user_agent, :string

      timestamps()
    end

    # Each credential_id must be unique across all users
    create unique_index(:passkey_credentials, [:credential_id])
    # Efficient lookup by user
    create index(:passkey_credentials, [:user_id])
    # Efficient lookup by user_handle for discoverable credentials
    create index(:passkey_credentials, [:user_handle])
  end
end
