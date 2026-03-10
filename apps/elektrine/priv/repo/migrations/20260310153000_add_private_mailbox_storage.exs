defmodule Elektrine.Repo.Migrations.AddPrivateMailboxStorage do
  use Ecto.Migration

  def change do
    alter table(:mailboxes) do
      add :private_storage_enabled, :boolean, default: false, null: false
      add :private_storage_public_key, :text
      add :private_storage_wrapped_private_key, :map
      add :private_storage_verifier, :map
    end

    alter table(:email_messages) do
      add :client_encrypted_payload, :map
    end
  end
end
