defmodule Elektrine.Repo.Migrations.RenameConversationsToSocialConversations do
  use Ecto.Migration

  def up do
    rename table(:conversations), to: table(:social_conversations)
    execute("ALTER SEQUENCE IF EXISTS conversations_id_seq RENAME TO social_conversations_id_seq")
  end

  def down do
    execute("ALTER SEQUENCE IF EXISTS social_conversations_id_seq RENAME TO conversations_id_seq")
    rename table(:social_conversations), to: table(:conversations)
  end
end
