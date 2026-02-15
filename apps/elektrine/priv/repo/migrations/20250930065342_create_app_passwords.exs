defmodule Elektrine.Repo.Migrations.CreateAppPasswords do
  use Ecto.Migration

  def change do
    create table(:app_passwords) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:app_passwords, [:user_id])
    create unique_index(:app_passwords, [:token_hash])
    create index(:app_passwords, [:expires_at])
  end
end
