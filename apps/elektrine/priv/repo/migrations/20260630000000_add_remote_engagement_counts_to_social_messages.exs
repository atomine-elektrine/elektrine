defmodule Elektrine.Repo.Migrations.AddRemoteEngagementCountsToSocialMessages do
  use Ecto.Migration

  def up do
    alter table(:social_messages) do
      add :remote_like_count, :integer
      add :remote_reply_count, :integer
      add :remote_share_count, :integer
      add :remote_quote_count, :integer
      add :remote_counts_fetched_at, :utc_datetime
    end

    execute("""
    UPDATE social_messages
    SET
      remote_like_count = CASE
        WHEN media_metadata->>'original_like_count' ~ '^[0-9]+$'
          THEN (media_metadata->>'original_like_count')::integer
        ELSE remote_like_count
      END,
      remote_reply_count = CASE
        WHEN media_metadata->>'original_reply_count' ~ '^[0-9]+$'
          THEN (media_metadata->>'original_reply_count')::integer
        ELSE remote_reply_count
      END,
      remote_share_count = CASE
        WHEN media_metadata->>'original_share_count' ~ '^[0-9]+$'
          THEN (media_metadata->>'original_share_count')::integer
        ELSE remote_share_count
      END
    WHERE media_metadata IS NOT NULL
    """)
  end

  def down do
    alter table(:social_messages) do
      remove :remote_counts_fetched_at
      remove :remote_quote_count
      remove :remote_share_count
      remove :remote_reply_count
      remove :remote_like_count
    end
  end
end
