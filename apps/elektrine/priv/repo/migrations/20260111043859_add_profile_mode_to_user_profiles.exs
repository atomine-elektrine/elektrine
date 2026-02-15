defmodule Elektrine.Repo.Migrations.AddProfileModeToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      # "builder" = existing drag & drop builder, "static" = custom uploaded files
      add :profile_mode, :string, default: "builder", null: false
      # Storage key for the index.html file when in static mode
      add :static_site_index, :string
    end

    # Create table for static site files
    create table(:static_site_files) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :storage_key, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:static_site_files, [:user_id])
    create unique_index(:static_site_files, [:user_id, :path])
  end
end
