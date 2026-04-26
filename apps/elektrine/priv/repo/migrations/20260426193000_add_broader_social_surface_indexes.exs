defmodule Elektrine.Repo.Migrations.AddBroaderSocialSurfaceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_id_idx
    ON social_messages (id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_timeline_post_id_idx
    ON social_messages (conversation_id, id DESC)
    WHERE post_type = 'post'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_timeline_sender_id_idx
    ON social_messages (sender_id, id DESC)
    WHERE post_type = 'post'
      AND deleted_at IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_inserted_id_idx
    ON social_messages (inserted_at DESC, id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_community_conversation_inserted_id_idx
    ON social_messages (conversation_id, inserted_at DESC, id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_community_actor_inserted_id_idx
    ON social_messages ((media_metadata->>'community_actor_uri'), inserted_at DESC, id DESC)
    WHERE visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
      AND (media_metadata->>'community_actor_uri') IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_gallery_public_inserted_idx
    ON social_messages (inserted_at DESC)
    WHERE post_type = 'gallery'
      AND visibility = 'public'
      AND deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_gallery_federated_inserted_idx
    ON social_messages (inserted_at DESC)
    WHERE federated = TRUE
      AND visibility IN ('public', 'unlisted')
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND array_length(media_urls, 1) > 0
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_gallery_federated_likes_idx
    ON social_messages (like_count DESC, inserted_at DESC)
    WHERE federated = TRUE
      AND visibility IN ('public', 'unlisted')
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND array_length(media_urls, 1) > 0
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_gallery_sender_inserted_idx
    ON social_messages (sender_id, inserted_at DESC)
    WHERE post_type = 'gallery'
      AND deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_media_sender_inserted_idx
    ON social_messages (sender_id, inserted_at DESC)
    WHERE deleted_at IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND array_length(media_urls, 1) > 0
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_conversations_public_community_member_idx
    ON social_conversations (member_count DESC, last_message_at DESC)
    WHERE type = 'community'
      AND is_public = TRUE
      AND (is_federated_mirror IS NULL OR is_federated_mirror = FALSE)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_members_user_active_community_idx
    ON conversation_members (user_id, conversation_id)
    WHERE left_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS conversation_members_user_active_community_idx")

    execute("DROP INDEX CONCURRENTLY IF EXISTS social_conversations_public_community_member_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_media_sender_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_gallery_sender_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_gallery_federated_likes_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_gallery_federated_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_gallery_public_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_community_actor_inserted_id_idx")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_community_conversation_inserted_id_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_inserted_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_timeline_sender_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_timeline_post_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_id_idx")
  end
end
