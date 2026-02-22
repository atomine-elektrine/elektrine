defmodule Elektrine.Messaging do
  @moduledoc """
  The Messaging context - handles conversations, messages, and real-time communication.

  This module serves as the main entry point and delegates to specialized sub-contexts:
  - `Elektrine.Messaging.Conversations` - Conversation management
  - `Elektrine.Messaging.Messages` - Message operations
  - `Elektrine.Messaging.Reactions` - Reaction handling
  - `Elektrine.Messaging.Moderation` - Moderation features
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  # Delegate to sub-contexts
  alias Elektrine.Messaging.ChatMessages
  alias Elektrine.Messaging.Conversations
  alias Elektrine.Messaging.Messages
  alias Elektrine.Messaging.Moderation
  alias Elektrine.Messaging.Reactions
  alias Elektrine.Messaging.Servers

  ## Conversations - Delegate to Conversations context

  @doc """
  Returns the list of conversations for a user.
  """
  defdelegate list_conversations(user_id, opts \\ []), to: Conversations

  @doc """
  Gets a single conversation with members and recent messages.
  """
  defdelegate get_conversation!(id, user_id), to: Conversations

  @doc """
  Gets a conversation for chat display without preloading messages.
  Lightweight version optimized for chat view where messages are loaded separately.
  """
  defdelegate get_conversation_for_chat!(id, user_id), to: Conversations

  @doc """
  Gets a conversation by its hash.
  """
  defdelegate get_conversation_by_hash(hash), to: Conversations

  @doc """
  Gets a conversation by its name (for communities).
  """
  defdelegate get_conversation_by_name(name), to: Conversations

  @doc """
  Gets moderators and admins for a community.
  """
  defdelegate get_community_moderators(community_id), to: Conversations

  @doc """
  Creates a direct message conversation between two users.
  """
  defdelegate create_dm_conversation(user1_id, user2_id), to: Conversations

  @doc """
  Checks if user can create more conversations of the given type.
  """
  defdelegate check_creation_limit(user_id, type), to: Conversations

  @doc """
  Creates a group conversation.
  """
  defdelegate create_group_conversation(creator_id, attrs, member_ids \\ []), to: Conversations

  @doc """
  Creates a channel.
  """
  defdelegate create_channel(creator_id, attrs), to: Conversations

  @doc """
  Updates a conversation (name, description, etc.).
  """
  defdelegate update_conversation(conversation, attrs), to: Conversations

  @doc """
  Deletes a conversation (admin/creator only).
  """
  defdelegate delete_conversation(conversation_id), to: Conversations

  @doc """
  Lists public channels.
  """
  defdelegate list_public_channels(opts \\ []), to: Conversations

  @doc """
  Lists public groups.
  """
  defdelegate list_public_groups(opts \\ []), to: Conversations

  @doc """
  Searches for public groups and channels that the user can join.
  """
  defdelegate search_public_conversations(query, current_user_id, limit \\ 10), to: Conversations

  @doc """
  Adds a member to a conversation.
  """
  defdelegate add_member_to_conversation(
                conversation_id,
                user_id,
                role \\ "member",
                added_by_user_id \\ nil
              ),
              to: Conversations

  @doc """
  Removes a member from a conversation.
  """
  defdelegate remove_member_from_conversation(conversation_id, user_id), to: Conversations

  @doc """
  Gets a conversation member record.
  """
  defdelegate get_conversation_member(conversation_id, user_id), to: Conversations

  @doc """
  Gets all members of a conversation.
  """
  defdelegate get_conversation_members(conversation_id), to: Conversations

  @doc """
  Promotes a member to admin role.
  """
  defdelegate promote_to_admin(conversation_id, user_id, promoter_id), to: Conversations

  @doc """
  Demotes an admin to regular member.
  """
  defdelegate demote_from_admin(conversation_id, user_id, demoter_id), to: Conversations

  @doc """
  Updates a member's role in a conversation.
  """
  defdelegate update_member_role(conversation_id, user_id, new_role), to: Conversations

  @doc """
  Promotes a user to moderator.
  """
  defdelegate promote_to_moderator(conversation_id, user_id), to: Conversations

  @doc """
  Demotes a moderator to member.
  """
  defdelegate demote_from_moderator(conversation_id, user_id), to: Conversations

  @doc """
  Joins a public conversation (channel or group).
  """
  defdelegate join_conversation(conversation_id, user_id), to: Conversations

  @doc """
  Joins a public channel.
  """
  defdelegate join_channel(channel_id, user_id), to: Conversations

  @doc """
  Pins a conversation for a user.
  """
  defdelegate pin_conversation(conversation_id, user_id), to: Conversations

  @doc """
  Unpins a conversation for a user.
  """
  defdelegate unpin_conversation(conversation_id, user_id), to: Conversations

  @doc """
  Allows a user to leave a conversation.
  """
  defdelegate leave_conversation(conversation_id, user_id), to: Conversations

  @doc """
  Checks if a user is the owner of a community.
  """
  defdelegate community_owner?(conversation_id, user_id), to: Conversations

  @doc """
  Checks if a user has any community memberships (for loading skeleton optimization).
  """
  defdelegate user_has_communities?(user_id), to: Conversations

  @doc """
  Checks if there are any communities in the system (for loading skeleton optimization).
  """
  defdelegate has_any_communities?(), to: Conversations

  @doc """
  Checks if a user has any chat conversations (for loading skeleton optimization).
  """
  defdelegate user_has_conversations?(user_id), to: Conversations

  ## Servers - Delegate to Servers context

  @doc """
  Lists servers where the user is an active member.
  """
  defdelegate list_servers(user_id, opts \\ []), to: Servers

  @doc """
  Gets a server with channels for a user.
  """
  defdelegate get_server(server_id, user_id), to: Servers

  @doc """
  Gets a server membership record.
  """
  defdelegate get_server_member(server_id, user_id), to: Servers

  @doc """
  Creates a new server with a default channel.
  """
  defdelegate create_server(creator_id, attrs), to: Servers

  @doc """
  Creates a new channel in a server.
  """
  defdelegate create_server_channel(server_id, creator_id, attrs), to: Servers

  @doc """
  Joins a public server.
  """
  defdelegate join_server(server_id, user_id), to: Servers

  ## Messages - Delegate to Messages context

  @doc """
  Creates a text message in a conversation.
  """
  defdelegate create_text_message(
                conversation_id,
                sender_id,
                content,
                reply_to_id \\ nil,
                opts \\ []
              ),
              to: Messages

  @doc """
  Creates a media message in a conversation.
  """
  defdelegate create_media_message(
                conversation_id,
                sender_id,
                media_urls,
                content \\ nil,
                media_metadata \\ %{}
              ),
              to: Messages

  @doc """
  Creates a voice message in a conversation.
  """
  defdelegate create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type),
    to: Messages

  @doc """
  Creates a system message in a conversation.
  """
  defdelegate create_system_message(conversation_id, content, metadata \\ %{}), to: Messages

  @doc """
  Edits a message.
  """
  defdelegate edit_message(message_id, user_id, new_content), to: Messages

  @doc """
  Deletes a message.
  """
  defdelegate delete_message(message_id, user_id, is_admin \\ false), to: Messages

  @doc """
  Admin deletes a message (bypasses ownership check).
  """
  defdelegate admin_delete_message(message_id, admin_user), to: Messages

  @doc """
  Get messages for a conversation with pagination support.
  """
  defdelegate get_conversation_messages(conversation_id, user_id, opts \\ []), to: Messages

  @doc """
  Gets messages for a conversation with pagination.
  """
  defdelegate get_messages(conversation_id, user_id, opts \\ []), to: Messages

  @doc """
  Searches messages within a specific conversation.
  """
  defdelegate search_messages_in_conversation(conversation_id, user_id, query, opts \\ []),
    to: Messages

  @doc """
  Marks messages as read for a user in a conversation.
  """
  defdelegate mark_as_read(conversation_id, user_id), to: Messages

  @doc """
  Updates the last read message for a user in a conversation.
  """
  defdelegate update_last_read_message(conversation_id, user_id, message_id), to: Messages

  @doc """
  Gets the last read message ID for a user in a conversation.
  """
  defdelegate get_last_read_message_id(conversation_id, user_id), to: Messages

  @doc """
  Clears message history for a specific user.
  """
  defdelegate clear_history_for_user(conversation_id, user_id), to: Messages

  @doc """
  Gets users who have read a specific message.
  """
  defdelegate get_message_readers(message_id, conversation_id), to: Messages

  @doc """
  Gets read status for messages in a conversation.
  """
  defdelegate get_read_status_for_messages(message_ids, conversation_id), to: Messages

  @doc """
  Gets read status for last messages across multiple conversations in a batch.
  """
  defdelegate get_batch_last_message_read_status(message_info_list), to: Messages

  @doc """
  Gets unread message count for a specific conversation and user.
  """
  defdelegate get_conversation_unread_count(conversation_id, user_id), to: Messages

  @doc """
  Gets unread message counts for multiple conversations in a single query.
  Returns a map of conversation_id => unread_count.
  """
  defdelegate get_conversation_unread_counts(conversation_ids, user_id), to: Messages

  @doc """
  Gets unread message count for a user across all conversations.
  """
  defdelegate get_unread_count(user_id), to: Messages

  @doc """
  Pins a message in a community (moderators only).
  """
  defdelegate pin_message(message_id, user_id), to: Messages

  @doc """
  Unpins a message in a community (moderators only).
  """
  defdelegate unpin_message(message_id, user_id), to: Messages

  @doc """
  Lists pinned messages for a conversation.
  """
  defdelegate list_pinned_messages(conversation_id), to: Messages

  @doc """
  Generates a friendly URL path for a discussion post.
  """
  defdelegate discussion_post_path(community_name, post_id, title), to: Messages

  @doc """
  Gets a user's discussion posts across all communities.
  """
  defdelegate get_user_discussion_posts(user_id, opts \\ []), to: Messages

  ## Chat Messages - Delegate to ChatMessages context
  ## (Separate from timeline posts for performance and clarity)

  @doc """
  Gets chat messages for a conversation with pagination.
  """
  defdelegate get_chat_messages(conversation_id, opts \\ []), to: ChatMessages, as: :get_messages

  @doc """
  Gets a single chat message by ID.
  """
  defdelegate get_chat_message(id), to: ChatMessages, as: :get_message

  @doc """
  Creates a text chat message.
  """
  defdelegate create_chat_text_message(conversation_id, sender_id, content, opts \\ []),
    to: ChatMessages,
    as: :create_text_message

  @doc """
  Creates a media chat message.
  """
  defdelegate create_chat_media_message(
                conversation_id,
                sender_id,
                media_urls,
                content \\ nil,
                media_metadata \\ %{}
              ), to: ChatMessages, as: :create_media_message

  @doc """
  Creates a voice chat message.
  """
  defdelegate create_chat_voice_message(
                conversation_id,
                sender_id,
                audio_url,
                duration,
                mime_type
              ), to: ChatMessages, as: :create_voice_message

  @doc """
  Creates a system chat message.
  """
  defdelegate create_chat_system_message(conversation_id, content),
    to: ChatMessages,
    as: :create_system_message

  @doc """
  Edits a chat message.
  """
  defdelegate edit_chat_message(message_id, user_id, new_content),
    to: ChatMessages,
    as: :edit_message

  @doc """
  Deletes a chat message.
  """
  defdelegate delete_chat_message(message_id, user_id, is_admin \\ false),
    to: ChatMessages,
    as: :delete_message

  @doc """
  Adds a reaction to a chat message.
  """
  defdelegate add_chat_reaction(message_id, user_id, emoji), to: ChatMessages, as: :add_reaction

  @doc """
  Removes a reaction from a chat message.
  """
  defdelegate remove_chat_reaction(message_id, user_id, emoji),
    to: ChatMessages,
    as: :remove_reaction

  @doc """
  Marks chat messages as read.
  """
  defdelegate mark_chat_messages_read(conversation_id, user_id, up_to_message_id \\ nil),
    to: ChatMessages,
    as: :mark_messages_read

  @doc """
  Gets unread chat message count for a conversation.
  """
  defdelegate get_chat_unread_count(conversation_id, user_id),
    to: ChatMessages,
    as: :get_unread_count

  @doc """
  Gets unread chat message counts for all conversations.
  """
  defdelegate get_all_chat_unread_counts(user_id), to: ChatMessages, as: :get_all_unread_counts

  @doc """
  Searches chat messages in a conversation.
  """
  defdelegate search_chat_messages(conversation_id, query, opts \\ []),
    to: ChatMessages,
    as: :search_messages

  ## Reactions - Delegate to Reactions context

  @doc """
  Adds a reaction to a message.
  """
  defdelegate add_reaction(message_id, user_id, emoji), to: Reactions

  @doc """
  Removes a reaction from a message.
  """
  defdelegate remove_reaction(message_id, user_id, emoji), to: Reactions

  ## Moderation - Delegate to Moderation context

  @doc """
  Creates a timeout for a user in a specific conversation or globally.
  """
  defdelegate timeout_user(user_id, created_by_id, duration_seconds, opts \\ []), to: Moderation

  @doc """
  Checks if a user is currently timed out in a conversation or globally.
  """
  defdelegate user_timed_out?(user_id, conversation_id \\ nil), to: Moderation

  @doc """
  Removes timeout for a user.
  """
  defdelegate remove_timeout(user_id, conversation_id \\ nil), to: Moderation

  @doc """
  Gets active timeouts for a user.
  """
  defdelegate get_user_timeouts(user_id), to: Moderation

  @doc """
  Remove member from conversation (kick).
  """
  defdelegate remove_member(conversation_id, user_id, current_user), to: Moderation

  @doc """
  Bans a user from a community.
  """
  defdelegate ban_user_from_community(
                community_id,
                user_id,
                banned_by_id,
                reason \\ nil,
                expires_at \\ nil
              ),
              to: Moderation

  @doc """
  Unbans a user from a community.
  """
  defdelegate unban_user_from_community(community_id, user_id, unbanned_by_id), to: Moderation

  @doc """
  Checks if a user is banned from a community.
  """
  defdelegate user_banned?(community_id, user_id), to: Moderation

  @doc """
  Lists banned users for a community.
  """
  defdelegate list_community_bans(community_id), to: Moderation

  @doc """
  Gets moderation actions for a conversation or user.
  """
  defdelegate get_moderation_log(opts \\ []), to: Moderation

  @doc """
  Log a moderation action.
  """
  defdelegate log_moderation_action(action_type, target_user_id, moderator_id, opts \\ []),
    to: Moderation

  @doc """
  Lists all flairs for a community.
  """
  defdelegate list_community_flairs(community_id), to: Moderation

  @doc """
  Lists enabled flairs for a community.
  """
  defdelegate list_enabled_community_flairs(community_id), to: Moderation

  @doc """
  Gets a single community flair.
  """
  defdelegate get_community_flair!(id), to: Moderation

  @doc """
  Lists flairs available to a user for a community.
  """
  defdelegate list_available_flairs(community_id, user_id), to: Moderation

  @doc """
  Gets a single flair.
  """
  defdelegate get_flair!(id), to: Moderation

  @doc """
  Creates a flair for a community.
  """
  defdelegate create_community_flair(attrs \\ %{}), to: Moderation

  @doc """
  Updates a flair.
  """
  defdelegate update_community_flair(flair, attrs), to: Moderation

  @doc """
  Deletes a flair.
  """
  defdelegate delete_community_flair(flair), to: Moderation

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking flair changes.
  """
  defdelegate change_community_flair(flair, attrs \\ %{}), to: Moderation

  ## Utility functions (kept in main context)

  @doc """
  Searches for users to start a conversation with.
  """
  def search_users(query, current_user_id, limit \\ 10) do
    search_term = "%#{query}%"

    from(u in User,
      where:
        u.id != ^current_user_id and
          (ilike(u.username, ^search_term) or
             ilike(u.display_name, ^search_term)),
      limit: ^limit,
      preload: [:profile]
    )
    |> Repo.all()
  end

  ## ActivityPub Federation - Delegate to Messages context

  @doc """
  Creates a message from a federated source (ActivityPub).
  """
  defdelegate create_federated_message(attrs), to: Messages

  @doc """
  Gets a message by its ActivityPub ID.
  """
  defdelegate get_message_by_activitypub_id(activitypub_id), to: Messages

  @doc """
  Gets a message by ActivityPub ID or URL reference.
  """
  defdelegate get_message_by_activitypub_ref(activitypub_ref), to: Messages

  @doc """
  Gets multiple messages by their ActivityPub IDs.
  """
  defdelegate get_messages_by_activitypub_ids(activitypub_ids), to: Messages

  @doc """
  Gets local replies to messages with the given ActivityPub IDs.
  """
  defdelegate get_local_replies_to_activitypub_ids(activitypub_ids), to: Messages

  @doc """
  Gets cached replies (local and federated) to messages with the given ActivityPub IDs.
  """
  defdelegate get_cached_replies_to_activitypub_ids(activitypub_ids), to: Messages

  @doc """
  Gets a message by ID.
  """
  defdelegate get_message(id), to: Messages

  @doc """
  Updates a message.
  """
  defdelegate update_message(message, attrs), to: Messages

  @doc """
  Creates a like from a federated source.
  """
  defdelegate create_federated_like(message_id, remote_actor_id), to: Messages

  @doc """
  Deletes a like from a federated source.
  """
  defdelegate delete_federated_like(message_id, remote_actor_id), to: Messages

  @doc """
  Creates a dislike (downvote) from a federated source.
  """
  defdelegate create_federated_dislike(message_id, remote_actor_id), to: Messages

  @doc """
  Deletes a dislike from a federated source.
  """
  defdelegate delete_federated_dislike(message_id, remote_actor_id), to: Messages

  @doc """
  Creates a boost (announce) record from a federated source.
  """
  defdelegate create_federated_boost(message_id, remote_actor_id), to: Messages

  @doc """
  Deletes a boost from a federated source.
  """
  defdelegate delete_federated_boost(message_id, remote_actor_id), to: Messages

  @doc """
  Increments the share count for a message.
  """
  defdelegate increment_share_count(message_id), to: Messages

  @doc """
  Decrements the share count for a message.
  """
  defdelegate decrement_share_count(message_id), to: Messages

  @doc """
  Increments the quote count for a message.
  """
  defdelegate increment_quote_count(message_id), to: Messages
end
