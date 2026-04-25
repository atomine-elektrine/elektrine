defmodule Elektrine.Repo.Migrations.AllowCommunityBansForChatConversations do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE community_bans DROP CONSTRAINT IF EXISTS community_bans_conversation_id_fkey"
  end

  def down do
    execute "ALTER TABLE community_bans ADD CONSTRAINT community_bans_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"
  end
end
