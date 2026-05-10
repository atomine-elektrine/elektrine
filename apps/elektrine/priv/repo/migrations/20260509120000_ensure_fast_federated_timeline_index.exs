defmodule Elektrine.Repo.Migrations.EnsureFastFederatedTimelineIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_federated_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND federated = TRUE
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)
  end

  def down do
    :ok
  end
end
