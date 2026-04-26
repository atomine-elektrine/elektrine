defmodule Elektrine.Repo.Migrations.AddHotPathSocialFeedIndexes do
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

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_community_actor_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
      AND (media_metadata->>'community_actor_uri') IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_reply_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NOT NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_inreplyto_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_federated_reply_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND federated = TRUE
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (reply_to_id IS NOT NULL OR (media_metadata->>'inReplyTo') IS NOT NULL)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activitypub_instances_blocked_lower_domain_idx
    ON activitypub_instances ((lower(domain)))
    WHERE blocked = TRUE
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS activitypub_instances_blocked_lower_domain_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_federated_reply_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_inreplyto_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_reply_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_community_actor_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_federated_id_idx")
  end
end
