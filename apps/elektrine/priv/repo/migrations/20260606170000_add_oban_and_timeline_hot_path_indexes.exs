defmodule Elektrine.Repo.Migrations.AddObanAndTimelineHotPathIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_available_queue_fetch_idx
    ON oban_jobs (queue, priority, scheduled_at, id)
    WHERE state = 'available' AND queue IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_prune_completed_scheduled_idx
    ON oban_jobs (scheduled_at, id)
    WHERE state = 'completed' AND queue IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_prune_cancelled_at_idx
    ON oban_jobs (cancelled_at, id)
    WHERE state = 'cancelled' AND queue IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_prune_discarded_at_idx
    ON oban_jobs (discarded_at, id)
    WHERE state = 'discarded' AND queue IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_worker_queue_state_inserted_idx
    ON oban_jobs (worker, queue, state, inserted_at DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_args_jsonb_path_idx
    ON oban_jobs USING GIN (args jsonb_path_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_community_conversation_id_idx
    ON social_messages (conversation_id, id DESC)
    WHERE visibility = 'public'
      AND is_draft IS NOT TRUE
      AND deleted_at IS NULL
      AND reply_to_id IS NULL
      AND (approval_status = 'approved' OR approval_status IS NULL)
      AND (media_metadata->>'inReplyTo') IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_public_top_community_actor_id_idx_v2
    ON social_messages ((media_metadata->>'community_actor_uri'), id DESC)
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
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_community_actor_id_idx_v2"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_public_top_community_conversation_id_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_args_jsonb_path_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_worker_queue_state_inserted_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_prune_discarded_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_prune_cancelled_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_prune_completed_scheduled_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_available_queue_fetch_idx")
  end
end
