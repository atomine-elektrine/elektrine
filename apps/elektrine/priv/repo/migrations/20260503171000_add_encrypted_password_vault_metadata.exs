defmodule Elektrine.Repo.Migrations.AddEncryptedPasswordVaultMetadata do
  use Ecto.Migration

  def change do
    alter table(:password_vault_entries) do
      add :encrypted_metadata, :map
    end
  end
end
