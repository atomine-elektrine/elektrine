defmodule Elektrine.Repo.Migrations.AddSiteSessionRollupIndexesForAnalytics do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS site_sessions_host_stats_idx
    ON site_sessions (entry_host)
    INCLUDE (page_views, started_at, duration_seconds)
    WHERE entry_host IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS site_sessions_host_path_stats_idx
    ON site_sessions (entry_host, entry_path)
    INCLUDE (page_views, started_at)
    WHERE entry_host IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS site_sessions_host_path_stats_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS site_sessions_host_stats_idx")
  end
end
