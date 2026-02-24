defmodule Elektrine.Repo.Migrations.AddHotPathFeedAndEmailIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_remote_actor_fed_public_top_level_inserted_idx
    ON messages (remote_actor_id, inserted_at DESC)
    WHERE federated = TRUE
      AND visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND remote_actor_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_community_actor_uri_fed_public_top_level_inserted_idx
    ON messages ((media_metadata->>'community_actor_uri'), inserted_at DESC)
    WHERE federated = TRUE
      AND visibility = 'public'
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (media_metadata->>'community_actor_uri') IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_mailbox_id_id_idx
    ON email_messages (mailbox_id, id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_mailbox_active_inserted_idx
    ON email_messages (mailbox_id, inserted_at DESC)
    WHERE spam = FALSE
      AND archived = FALSE
      AND deleted = FALSE
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_active_inserted_idx
    ON email_messages (inserted_at DESC)
    WHERE spam = FALSE
      AND archived = FALSE
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS messages_remote_actor_fed_public_top_level_inserted_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS messages_community_actor_uri_fed_public_top_level_inserted_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS email_messages_mailbox_id_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS email_messages_mailbox_active_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS email_messages_active_inserted_idx")
  end
end
