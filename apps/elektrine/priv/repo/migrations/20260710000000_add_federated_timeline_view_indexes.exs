defmodule Elektrine.Repo.Migrations.AddFederatedTimelineViewIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_federated_media_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND is_draft IS NOT TRUE
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND federated = TRUE
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
      AND array_length(media_urls, 1) > 0
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_federated_reply_id_idx_v2
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND is_draft IS NOT TRUE
      AND deleted_at IS NULL
      AND federated = TRUE
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (reply_to_id IS NOT NULL OR (media_metadata->>'inReplyTo') IS NOT NULL)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_federated_reply_id_idx_v2")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_federated_media_id_idx")
  end
end
