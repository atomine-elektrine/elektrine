defmodule Elektrine.Repo.Migrations.RenameSocialMessagingTables do
  use Ecto.Migration

  def up do
    rename table(:messages), to: table(:social_messages)
    rename table(:conversations), to: table(:social_conversations)

    execute("ALTER SEQUENCE IF EXISTS messages_id_seq RENAME TO social_messages_id_seq")
    execute("ALTER SEQUENCE IF EXISTS conversations_id_seq RENAME TO social_conversations_id_seq")
  end

  def down do
    execute("ALTER SEQUENCE IF EXISTS social_messages_id_seq RENAME TO messages_id_seq")
    execute("ALTER SEQUENCE IF EXISTS social_conversations_id_seq RENAME TO conversations_id_seq")

    rename table(:social_conversations), to: table(:conversations)
    rename table(:social_messages), to: table(:messages)
  end
end
