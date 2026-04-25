defmodule Elektrine.Repo.Migrations.AddLiteralLegacyActivitypubRefIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_activitypub_id_legacy_ref_literal_idx
    ON social_messages ((trim(trailing '/' from split_part(split_part(activitypub_id, '#', 1), '?', 1))))
    WHERE activitypub_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS social_messages_activitypub_url_legacy_ref_literal_idx
    ON social_messages ((trim(trailing '/' from split_part(split_part(activitypub_url, '#', 1), '?', 1))))
    WHERE activitypub_url IS NOT NULL
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_activitypub_url_legacy_ref_literal_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS social_messages_activitypub_id_legacy_ref_literal_idx"
    )
  end
end
