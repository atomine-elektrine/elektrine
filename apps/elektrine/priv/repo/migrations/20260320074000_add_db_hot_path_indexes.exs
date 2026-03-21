defmodule Elektrine.Repo.Migrations.AddDbHotPathIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_inbox_unread_folderless_inserted_idx
    ON email_messages (mailbox_id, inserted_at DESC)
    WHERE read = FALSE
      AND spam = FALSE
      AND archived = FALSE
      AND deleted = FALSE
      AND reply_later_at IS NULL
      AND folder_id IS NULL
      AND (category IS NULL OR category NOT IN ('feed', 'ledger', 'stack'))
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_folder_mailbox_active_inserted_idx
    ON email_messages (folder_id, mailbox_id, inserted_at DESC)
    WHERE deleted = FALSE
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_email_inbound_idempotency_key_idx
    ON oban_jobs (worker, queue, ((args->>'idempotency_key')), state)
    WHERE queue = 'email_inbound'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activitypub_activities_pending_remote_inserted_idx
    ON activitypub_activities (inserted_at, id)
    WHERE processed = FALSE
      AND local = FALSE
      AND process_attempts < 2
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activitypub_deliveries_pending_retry_updated_idx
    ON activitypub_deliveries (next_retry_at, updated_at, id)
    WHERE status = 'pending'
      AND attempts < 10
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS email_messages_inbox_unread_folderless_inserted_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS email_messages_folder_mailbox_active_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_email_inbound_idempotency_key_idx")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS activitypub_activities_pending_remote_inserted_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS activitypub_deliveries_pending_retry_updated_idx")
  end
end
