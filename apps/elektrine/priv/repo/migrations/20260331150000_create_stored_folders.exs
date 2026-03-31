defmodule Elektrine.Repo.Migrations.CreateStoredFolders do
  use Ecto.Migration

  def change do
    create table(:stored_folders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :path, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stored_folders, [:user_id, :path])
    create index(:stored_folders, [:user_id])
  end
end
