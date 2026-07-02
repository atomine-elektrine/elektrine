defmodule Elektrine.Repo.Migrations.CreateBookmarkFolders do
  use Ecto.Migration

  def change do
    create table(:bookmark_folders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :emoji, :string

      timestamps()
    end

    create unique_index(:bookmark_folders, [:user_id, :name])
    create index(:bookmark_folders, [:user_id])

    alter table(:saved_items) do
      add :bookmark_folder_id, references(:bookmark_folders, on_delete: :nilify_all)
    end

    create index(:saved_items, [:user_id, :bookmark_folder_id])
  end
end
