defmodule Elektrine.Repo.Migrations.BackfillChatConversationHashes do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_conversations
    SET hash = lower(md5(random()::text || clock_timestamp()::text || id::text))
    WHERE hash IS NULL OR hash = ''
    """)
  end

  def down do
    :ok
  end
end
