defmodule Elektrine.Repo.Migrations.AddChatClientEncryption do
  use Ecto.Migration

  def change do
    create table(:chat_encryption_devices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :device_id, :string, null: false
      add :public_key, :map, null: false
      add :key_algorithm, :string, null: false, default: "RSA-OAEP-SHA256"
      add :label, :string
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:chat_encryption_devices, [:user_id, :device_id])

    create index(:chat_encryption_devices, [:user_id],
             where: "revoked_at IS NULL",
             name: :chat_encryption_devices_active_user_idx
           )

    create table(:chat_conversation_encryption_keys) do
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all), null: false
      add :key_uid, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :algorithm, :string, null: false, default: "AES-256-GCM"
      add :active, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:chat_conversation_encryption_keys, [:conversation_id, :key_uid])
    create index(:chat_conversation_encryption_keys, [:conversation_id, :active])

    create table(:chat_conversation_key_recipients) do
      add :conversation_key_id,
          references(:chat_conversation_encryption_keys, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :device_id, :string, null: false
      add :wrapped_key, :map, null: false

      timestamps()
    end

    create unique_index(:chat_conversation_key_recipients, [
             :conversation_key_id,
             :user_id,
             :device_id
           ])

    create index(:chat_conversation_key_recipients, [:user_id, :device_id])

    alter table(:chat_messages) do
      add :client_encrypted_payload, :map

      add :client_encryption_key_id,
          references(:chat_conversation_encryption_keys, on_delete: :nilify_all)
    end

    create index(:chat_messages, [:client_encryption_key_id])
  end
end
