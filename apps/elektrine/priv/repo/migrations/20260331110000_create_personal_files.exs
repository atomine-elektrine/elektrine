defmodule Elektrine.Repo.Migrations.CreatePersonalFiles do
  use Ecto.Migration

  def change do
    create table(:stored_files) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :storage_key, :string, null: false
      add :original_filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stored_files, [:user_id, :path])
    create index(:stored_files, [:user_id])

    create table(:file_shares) do
      add :stored_file_id, references(:stored_files, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :revoked_at, :utc_datetime
      add :download_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:file_shares, [:token])
    create index(:file_shares, [:stored_file_id])
    create index(:file_shares, [:user_id])
  end
end
