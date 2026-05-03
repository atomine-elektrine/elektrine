defmodule Elektrine.Repo.Migrations.AddChatMessagesSearchIndexGin do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS chat_messages_search_index_gin_idx
    ON chat_messages USING gin (search_index)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS chat_messages_search_index_gin_idx")
  end
end
