defmodule Elektrine.Repo.Migrations.AddSocialMessagesCommunityActorUriIdDescIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_community_actor_uri_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND is_draft IS NOT TRUE
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
      AND (media_metadata->>'community_actor_uri') IS NOT NULL
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_community_actor_uri_id_idx"
    )
  end
end
