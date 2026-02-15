defmodule Elektrine.Repo.Migrations.CreatePasswordVaultEntries do
  use Ecto.Migration

  def change do
    create table(:password_vault_entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :login_username, :string
      add :website, :string
      add :encrypted_password, :map, null: false
      add :encrypted_notes, :map

      timestamps(type: :utc_datetime)
    end

    create index(:password_vault_entries, [:user_id])
    create index(:password_vault_entries, [:user_id, :inserted_at])
  end
end
