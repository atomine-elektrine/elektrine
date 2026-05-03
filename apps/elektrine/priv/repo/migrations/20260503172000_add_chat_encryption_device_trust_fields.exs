defmodule Elektrine.Repo.Migrations.AddChatEncryptionDeviceTrustFields do
  use Ecto.Migration

  def change do
    alter table(:chat_encryption_devices) do
      add :fingerprint, :string
      add :signing_public_key, :map
      add :device_signature, :map
    end

    alter table(:chat_remote_encryption_devices) do
      add :fingerprint, :string
      add :signing_public_key, :map
      add :device_signature, :map
    end

    create index(:chat_encryption_devices, [:user_id, :fingerprint])
    create index(:chat_remote_encryption_devices, [:origin_domain, :remote_handle, :fingerprint])
  end
end
