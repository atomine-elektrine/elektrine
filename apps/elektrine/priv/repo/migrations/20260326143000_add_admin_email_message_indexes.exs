defmodule Elektrine.Repo.Migrations.AddAdminEmailMessageIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS email_messages_status_inserted_at_idx
    ON email_messages (status, inserted_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS email_messages_status_inserted_at_idx")
  end
end
