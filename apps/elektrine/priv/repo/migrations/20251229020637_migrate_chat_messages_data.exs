defmodule Elektrine.Repo.Migrations.MigrateChatMessagesData do
  use Ecto.Migration

  @moduledoc """
  Migrates existing chat messages from the `messages` table to the new `chat_messages` table.

  This migration:
  1. Copies messages from DM/group/channel conversations to chat_messages
  2. Preserves original IDs so reply_to_id references work
  3. Copies reactions from message_reactions to chat_message_reactions
  4. Updates sequences for the new tables
  """

  def up do
    # Step 1: Copy messages from DM/group/channel conversations
    # We preserve the original IDs to maintain reply_to_id relationships
    execute """
    INSERT INTO chat_messages (
      id,
      conversation_id,
      sender_id,
      content,
      encrypted_content,
      search_index,
      message_type,
      media_urls,
      media_metadata,
      reply_to_id,
      edited_at,
      deleted_at,
      inserted_at,
      updated_at
    )
    SELECT
      m.id,
      m.conversation_id,
      m.sender_id,
      m.content,
      m.encrypted_content,
      COALESCE(m.search_index, ARRAY[]::varchar[]),
      m.message_type,
      COALESCE(m.media_urls, ARRAY[]::varchar[]),
      COALESCE(m.media_metadata, '{}'::jsonb),
      m.reply_to_id,
      m.edited_at,
      m.deleted_at,
      m.inserted_at,
      m.updated_at
    FROM messages m
    INNER JOIN conversations c ON m.conversation_id = c.id
    WHERE c.type IN ('dm', 'group', 'channel')
    ON CONFLICT (id) DO NOTHING
    """

    # Step 2: Update the sequence to avoid ID conflicts for new messages
    execute """
    SELECT setval(
      'chat_messages_id_seq',
      GREATEST(
        (SELECT COALESCE(MAX(id), 0) FROM chat_messages),
        (SELECT last_value FROM chat_messages_id_seq)
      )
    )
    """

    # Step 3: Copy reactions for migrated messages
    execute """
    INSERT INTO chat_message_reactions (
      chat_message_id,
      user_id,
      remote_actor_id,
      emoji,
      inserted_at,
      updated_at
    )
    SELECT
      mr.message_id,
      mr.user_id,
      mr.remote_actor_id,
      mr.emoji,
      mr.inserted_at,
      mr.updated_at
    FROM message_reactions mr
    INNER JOIN chat_messages cm ON mr.message_id = cm.id
    ON CONFLICT DO NOTHING
    """

    # Step 4: Update the reactions sequence
    execute """
    SELECT setval(
      'chat_message_reactions_id_seq',
      GREATEST(
        (SELECT COALESCE(MAX(id), 0) FROM chat_message_reactions),
        (SELECT last_value FROM chat_message_reactions_id_seq)
      )
    )
    """
  end

  def down do
    # Remove migrated data (but keep the tables)
    execute """
    DELETE FROM chat_message_reactions
    WHERE chat_message_id IN (
      SELECT cm.id FROM chat_messages cm
      INNER JOIN conversations c ON cm.conversation_id = c.id
      WHERE c.type IN ('dm', 'group', 'channel')
    )
    """

    execute """
    DELETE FROM chat_messages
    WHERE conversation_id IN (
      SELECT id FROM conversations
      WHERE type IN ('dm', 'group', 'channel')
    )
    """
  end
end
