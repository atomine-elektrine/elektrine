defmodule Elektrine.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Messages table indexes
    create_if_not_exists index(:messages, [:sender_id])
    create_if_not_exists index(:messages, [:conversation_id, :deleted_at])
    create_if_not_exists index(:messages, [:reply_to_id])
    create_if_not_exists index(:messages, [:shared_message_id])
    create_if_not_exists index(:messages, [:link_preview_id])

    # Descending index for chronological sorting
    execute "CREATE INDEX IF NOT EXISTS messages_inserted_at_desc_index ON messages (inserted_at DESC)",
            "DROP INDEX IF EXISTS messages_inserted_at_desc_index"

    # Composite index for common query pattern
    create_if_not_exists index(:messages, [:post_type, :visibility],
                           where: "deleted_at IS NULL",
                           name: :messages_post_type_visibility_active_index
                         )

    # Post likes indexes
    create_if_not_exists index(:post_likes, [:message_id])
    create_if_not_exists index(:post_likes, [:user_id, :message_id])

    # Conversation members indexes
    create_if_not_exists index(:conversation_members, [:user_id, :conversation_id],
                           where: "left_at IS NULL",
                           name: :conversation_members_active_index
                         )

    create_if_not_exists index(:conversation_members, [:last_read_at])

    # Follows indexes
    create_if_not_exists index(:follows, [:follower_id, :followed_id])

    # Notifications indexes
    create_if_not_exists index(:notifications, [:user_id, :read_at, :dismissed_at],
                           name: :notifications_user_status_index
                         )

    create_if_not_exists index(:notifications, [:source_type, :source_id])

    # Post views indexes (only if table exists)
    execute """
            DO $$
            BEGIN
              IF EXISTS (SELECT FROM pg_tables WHERE tablename = 'post_views') THEN
                CREATE INDEX IF NOT EXISTS post_views_user_message_index ON post_views (user_id, message_id);
                CREATE INDEX IF NOT EXISTS post_views_message_index ON post_views (message_id);
                CREATE INDEX IF NOT EXISTS post_views_inserted_at_index ON post_views (inserted_at);
              END IF;
            END $$;
            """,
            ""

    # Hashtags indexes (only if table exists)
    execute """
            DO $$
            BEGIN
              IF EXISTS (SELECT FROM pg_tables WHERE tablename = 'hashtags') THEN
                CREATE INDEX IF NOT EXISTS hashtags_normalized_name_index ON hashtags (normalized_name);
                CREATE INDEX IF NOT EXISTS hashtags_use_count_desc_index ON hashtags (use_count DESC);
              END IF;
            END $$;
            """,
            ""

    # Message hashtags indexes (only if table exists)
    execute """
            DO $$
            BEGIN
              IF EXISTS (SELECT FROM pg_tables WHERE tablename = 'message_hashtags') THEN
                CREATE INDEX IF NOT EXISTS message_hashtags_message_index ON message_hashtags (message_id);
                CREATE INDEX IF NOT EXISTS message_hashtags_hashtag_index ON message_hashtags (hashtag_id);
              END IF;
            END $$;
            """,
            ""
  end
end
