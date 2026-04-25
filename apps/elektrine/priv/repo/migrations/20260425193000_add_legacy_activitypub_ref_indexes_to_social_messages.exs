defmodule Elektrine.Repo.Migrations.AddLegacyActivitypubRefIndexesToSocialMessages do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_activitypub_id_legacy_ref_idx
    ON social_messages ((trim(trailing '/' from split_part(split_part(activitypub_id, '#', 1), chr(63), 1))))
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_activitypub_url_legacy_ref_idx
    ON social_messages ((trim(trailing '/' from split_part(split_part(activitypub_url, '#', 1), chr(63), 1))))
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_activitypub_url_legacy_ref_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS social_messages_activitypub_id_legacy_ref_idx")
  end
end
