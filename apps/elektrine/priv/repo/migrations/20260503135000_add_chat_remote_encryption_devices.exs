defmodule Elektrine.Repo.Migrations.AddChatRemoteEncryptionDevices do
  use Ecto.Migration

  def change do
    create table(:chat_remote_encryption_devices) do
      add :origin_domain, :string, null: false
      add :remote_handle, :string, null: false
      add :device_id, :string, null: false
      add :public_key, :map, null: false
      add :key_algorithm, :string, null: false, default: "RSA-OAEP-SHA256"
      add :label, :string
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:chat_remote_encryption_devices, [
             :origin_domain,
             :remote_handle,
             :device_id
           ])

    create index(:chat_remote_encryption_devices, [:remote_handle],
             where: "revoked_at IS NULL",
             name: :chat_remote_encryption_devices_active_handle_idx
           )
  end
end
