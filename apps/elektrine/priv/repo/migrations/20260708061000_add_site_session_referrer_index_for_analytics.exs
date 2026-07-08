defmodule Elektrine.Repo.Migrations.AddSiteSessionReferrerIndexForAnalytics do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS site_sessions_host_referrer_stats_idx
    ON site_sessions (entry_host, referer)
    INCLUDE (started_at)
    WHERE entry_host IS NOT NULL AND referer IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS site_sessions_host_referrer_stats_idx")
  end
end
