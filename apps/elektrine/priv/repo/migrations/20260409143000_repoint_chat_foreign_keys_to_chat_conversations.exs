defmodule Elektrine.Repo.Migrations.RepointChatForeignKeysToChatConversations do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_conversation_id_fkey"

    execute "ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_conversation_id_fkey"

    execute "ALTER TABLE calls ADD CONSTRAINT calls_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_extension_events DROP CONSTRAINT IF EXISTS messaging_federation_extension_events_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_extension_events ADD CONSTRAINT messaging_federation_extension_events_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_read_cursors DROP CONSTRAINT IF EXISTS messaging_federation_read_cursors_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_read_cursors ADD CONSTRAINT messaging_federation_read_cursors_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_invite_states DROP CONSTRAINT IF EXISTS messaging_federation_invite_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_invite_states ADD CONSTRAINT messaging_federation_invite_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_membership_states DROP CONSTRAINT IF EXISTS messaging_federation_membership_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_membership_states ADD CONSTRAINT messaging_federation_membership_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_room_presence_states DROP CONSTRAINT IF EXISTS messaging_federation_room_presence_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_room_presence_states ADD CONSTRAINT messaging_federation_room_presence_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_call_sessions DROP CONSTRAINT IF EXISTS messaging_federation_call_sessions_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_call_sessions ADD CONSTRAINT messaging_federation_call_sessions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE"
  end

  def down do
    execute "ALTER TABLE messaging_federation_call_sessions DROP CONSTRAINT IF EXISTS messaging_federation_call_sessions_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_call_sessions ADD CONSTRAINT messaging_federation_call_sessions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_room_presence_states DROP CONSTRAINT IF EXISTS messaging_federation_room_presence_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_room_presence_states ADD CONSTRAINT messaging_federation_room_presence_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_membership_states DROP CONSTRAINT IF EXISTS messaging_federation_membership_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_membership_states ADD CONSTRAINT messaging_federation_membership_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_invite_states DROP CONSTRAINT IF EXISTS messaging_federation_invite_states_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_invite_states ADD CONSTRAINT messaging_federation_invite_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_read_cursors DROP CONSTRAINT IF EXISTS messaging_federation_read_cursors_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_read_cursors ADD CONSTRAINT messaging_federation_read_cursors_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE messaging_federation_extension_events DROP CONSTRAINT IF EXISTS messaging_federation_extension_events_conversation_id_fkey"

    execute "ALTER TABLE messaging_federation_extension_events ADD CONSTRAINT messaging_federation_extension_events_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_conversation_id_fkey"

    execute "ALTER TABLE calls ADD CONSTRAINT calls_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"

    execute "ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_conversation_id_fkey"

    execute "ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE"
  end
end
