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

    # Databases where messages_activitypub_id_index went INVALID (a failed
    # concurrent build) accumulated duplicate activitypub_id rows, and the
    # still-enforcing index then rejects ANY row update that touches them.
    # Soft-delete every duplicate except the oldest and clear its refs before
    # the backfill below rewrites those rows. Setting activitypub_id to NULL
    # keeps the row outside the partial unique index, so this update itself
    # cannot conflict.
    execute("""
    WITH duplicate_refs AS (
      SELECT activitypub_id
      FROM social_messages
      WHERE activitypub_id IS NOT NULL
      GROUP BY activitypub_id
      HAVING COUNT(*) > 1
    ),
    ranked AS (
      SELECT m.id,
             ROW_NUMBER() OVER (PARTITION BY m.activitypub_id ORDER BY m.id) AS row_rank
      FROM social_messages m
      JOIN duplicate_refs d ON d.activitypub_id = m.activitypub_id
    )
    UPDATE social_messages m
    SET activitypub_id = NULL,
        activitypub_id_canonical = NULL,
        deleted_at = COALESCE(m.deleted_at, NOW())
    FROM ranked r
    WHERE m.id = r.id
      AND r.row_rank > 1
    """)

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
