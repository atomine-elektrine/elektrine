defmodule Elektrine.Repo.Migrations.CreateKairoTables do
  use Ecto.Migration

  def change do
    create table(:kairo_projects) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :autonomy_level, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:kairo_projects, [:user_id])
    create unique_index(:kairo_projects, [:user_id, :slug])

    create table(:kairo_sources) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :project_id, references(:kairo_projects, on_delete: :delete_all)
      add :source_type, :string, null: false
      add :title, :string
      add :url, :text
      add :content, :text
      add :content_format, :string
      add :status, :string, null: false, default: "received"
      add :tags, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :raw_hash, :string
      add :error_message, :text
      add :ingested_at, :utc_datetime
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:kairo_sources, [:user_id])
    create index(:kairo_sources, [:project_id])
    create index(:kairo_sources, [:source_type])
    create index(:kairo_sources, [:status])
    create index(:kairo_sources, [:raw_hash])
  end
end
