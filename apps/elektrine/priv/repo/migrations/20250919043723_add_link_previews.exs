defmodule Elektrine.Repo.Migrations.AddLinkPreviews do
  use Ecto.Migration

  def change do
    create table(:link_previews) do
      add :url, :text, null: false
      add :title, :string
      add :description, :text
      add :image_url, :string
      add :site_name, :string
      add :favicon_url, :string
      add :status, :string, default: "pending"
      add :error_message, :text
      add :fetched_at, :utc_datetime

      timestamps()
    end

    # Add link preview association to messages
    alter table(:messages) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
      add :extracted_urls, {:array, :string}, default: []
    end

    # Add indexes for performance
    create unique_index(:link_previews, [:url])
    create index(:link_previews, [:status])
    create index(:messages, [:link_preview_id])
  end
end
