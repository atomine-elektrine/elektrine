defmodule Elektrine.Repo.Migrations.RestoreConversationsTableName do
  use Ecto.Migration

  def up do
    rename table(:social_conversations), to: table(:conversations)
    execute("ALTER SEQUENCE IF EXISTS social_conversations_id_seq RENAME TO conversations_id_seq")
  end

  def down do
    rename table(:conversations), to: table(:social_conversations)
    execute("ALTER SEQUENCE IF EXISTS conversations_id_seq RENAME TO social_conversations_id_seq")
  end
end
