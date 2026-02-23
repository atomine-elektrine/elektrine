defmodule Elektrine.Repo.Migrations.CreatePasswordVaultSettings do
  use Ecto.Migration

  def change do
    create table(:password_vault_settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :encrypted_verifier, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:password_vault_settings, [:user_id])
  end
end
