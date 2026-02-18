defmodule ElektrineChat do
  @moduledoc """
  Chat application facade.

  This module is the primary API surface for chat use-cases consumed by
  `elektrine_web` and other clients. It delegates to `Elektrine.Messaging`
  during migration so call sites can move first without behavior changes.
  """

  alias Elektrine.Messaging

  # Conversations and discovery
  defdelegate list_conversations(user_id, opts \\ []), to: Messaging
  defdelegate user_has_conversations?(user_id), to: Messaging
  defdelegate get_conversation!(id, user_id), to: Messaging
  defdelegate get_conversation_unread_count(conversation_id, user_id), to: Messaging
  defdelegate get_conversation_for_chat!(id, user_id), to: Messaging
  defdelegate get_conversation_by_hash(hash), to: Messaging
  defdelegate search_public_conversations(query, current_user_id, limit \\ 10), to: Messaging
  defdelegate list_public_channels(opts \\ []), to: Messaging
  defdelegate list_public_groups(opts \\ []), to: Messaging
  defdelegate join_conversation(conversation_id, user_id), to: Messaging
  defdelegate leave_conversation(conversation_id, user_id), to: Messaging
  defdelegate pin_conversation(conversation_id, user_id), to: Messaging
  defdelegate unpin_conversation(conversation_id, user_id), to: Messaging
  defdelegate update_conversation(conversation, attrs), to: Messaging
  defdelegate delete_conversation(conversation_id), to: Messaging
  defdelegate clear_history_for_user(conversation_id, user_id), to: Messaging
  defdelegate create_dm_conversation(user1_id, user2_id), to: Messaging
  defdelegate create_group_conversation(creator_id, attrs, member_ids \\ []), to: Messaging
  defdelegate create_channel(creator_id, attrs), to: Messaging

  defdelegate add_member_to_conversation(
                conversation_id,
                user_id,
                role \\ "member",
                added_by_user_id \\ nil
              ),
              to: Messaging

  defdelegate remove_member_from_conversation(conversation_id, user_id), to: Messaging
  defdelegate update_member_role(conversation_id, user_id, new_role), to: Messaging
  defdelegate get_conversation_member(conversation_id, user_id), to: Messaging
  defdelegate get_conversation_members(conversation_id), to: Messaging

  # Messages and reactions
  defdelegate get_conversation_messages(conversation_id, user_id, opts \\ []), to: Messaging
  defdelegate get_messages(conversation_id, user_id, opts \\ []), to: Messaging

  defdelegate create_text_message(
                conversation_id,
                sender_id,
                content,
                reply_to_id \\ nil,
                opts \\ []
              ),
              to: Messaging

  defdelegate create_media_message(
                conversation_id,
                sender_id,
                media_urls,
                content \\ nil,
                media_metadata \\ %{}
              ),
              to: Messaging

  defdelegate create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type),
    to: Messaging

  defdelegate delete_message(message_id, user_id, is_admin \\ false), to: Messaging
  defdelegate admin_delete_message(message_id, admin_user), to: Messaging
  defdelegate add_reaction(message_id, user_id, emoji), to: Messaging
  defdelegate pin_message(message_id, user_id), to: Messaging
  defdelegate unpin_message(message_id, user_id), to: Messaging

  defdelegate create_chat_text_message(conversation_id, sender_id, content, opts \\ []),
    to: Messaging

  defdelegate create_chat_media_message(
                conversation_id,
                sender_id,
                media_urls,
                content \\ nil,
                media_metadata \\ %{}
              ),
              to: Messaging

  defdelegate create_chat_voice_message(
                conversation_id,
                sender_id,
                audio_url,
                duration,
                mime_type
              ),
              to: Messaging

  defdelegate edit_chat_message(message_id, user_id, new_content), to: Messaging
  defdelegate delete_chat_message(message_id, user_id, is_admin \\ false), to: Messaging
  defdelegate add_chat_reaction(message_id, user_id, emoji), to: Messaging
  defdelegate remove_chat_reaction(message_id, user_id, emoji), to: Messaging

  defdelegate search_messages_in_conversation(conversation_id, user_id, query, opts \\ []),
    to: Messaging

  # Read state and unread counters
  defdelegate mark_as_read(conversation_id, user_id), to: Messaging
  defdelegate update_last_read_message(conversation_id, user_id, message_id), to: Messaging
  defdelegate get_read_status_for_messages(message_ids, conversation_id), to: Messaging
  defdelegate get_unread_count(user_id), to: Messaging
  defdelegate get_conversation_unread_counts(conversation_ids, user_id), to: Messaging
  defdelegate get_batch_last_message_read_status(message_info_list), to: Messaging

  defdelegate mark_chat_messages_read(conversation_id, user_id, up_to_message_id \\ nil),
    to: Messaging

  defdelegate get_all_chat_unread_counts(user_id), to: Messaging

  # Search and moderation
  defdelegate list_servers(user_id, opts \\ []), to: Messaging
  defdelegate get_server(server_id, user_id), to: Messaging
  defdelegate get_server_member(server_id, user_id), to: Messaging
  defdelegate create_server(creator_id, attrs), to: Messaging
  defdelegate create_server_channel(server_id, creator_id, attrs), to: Messaging
  defdelegate join_server(server_id, user_id), to: Messaging

  defdelegate search_users(query, current_user_id, opts \\ []), to: Messaging
  defdelegate timeout_user(user_id, created_by_id, duration_seconds, opts \\ []), to: Messaging
  defdelegate remove_timeout(user_id, conversation_id \\ nil), to: Messaging
  defdelegate user_timed_out?(user_id, conversation_id \\ nil), to: Messaging

  defdelegate log_moderation_action(action, target_user_id, performed_by_id, opts \\ []),
    to: Messaging
end
