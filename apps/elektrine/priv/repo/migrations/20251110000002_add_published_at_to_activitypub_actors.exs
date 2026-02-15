defmodule Elektrine.Repo.Migrations.AddPublishedAtToActivitypubActors do
  use Ecto.Migration

  def change do
    alter table(:activitypub_actors) do
      add :published_at, :utc_datetime
    end

    # Parse published date from metadata for existing actors
    execute """
            UPDATE activitypub_actors
            SET published_at = (metadata->>'published')::timestamp
            WHERE metadata->>'published' IS NOT NULL
            """,
            ""
  end
end
