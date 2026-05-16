defmodule Elektrine.Repo.Migrations.AddDbIndexesForSiteAnalyticsAndObanQueueStats do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS site_page_visits_host_visitor_stats_idx
    ON site_page_visits (
      request_host,
      (COALESCE(CAST(viewer_user_id AS text), visitor_id, ip_address))
    )
    INCLUDE (id, inserted_at)
    WHERE request_host IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_available_queue_idx
    ON oban_jobs (queue)
    WHERE state = 'available' AND queue IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_available_queue_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS site_page_visits_host_visitor_stats_idx")
  end
end
