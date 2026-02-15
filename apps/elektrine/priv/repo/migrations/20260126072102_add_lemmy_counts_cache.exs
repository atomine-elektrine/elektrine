defmodule Elektrine.Repo.Migrations.AddLemmyCountsCache do
  use Ecto.Migration

  def change do
    create table(:lemmy_counts_cache) do
      add :activitypub_id, :text, null: false
      add :upvotes, :integer, default: 0
      add :downvotes, :integer, default: 0
      add :score, :integer, default: 0
      add :comments, :integer, default: 0
      add :top_comments, :jsonb, default: "[]"
      add :fetched_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:lemmy_counts_cache, [:activitypub_id])
    create index(:lemmy_counts_cache, [:fetched_at])
  end
end
