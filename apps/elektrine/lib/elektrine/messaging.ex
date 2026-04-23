defmodule Elektrine.Messaging do
  @moduledoc """
  The Messaging context - handles conversations, messages, and real-time communication.

  This module serves as the main entry point and delegates to specialized sub-contexts:
  - `Elektrine.Social.Conversations` - Social conversation management
  - `Elektrine.Social.Messages` - Social message operations
  - `Elektrine.Messaging.Reactions` - Reaction handling
  - `Elektrine.Messaging.Moderation` - Moderation features
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  # Delegate to sub-contexts
  alias Elektrine.Messaging.{
    ChatConversation,
    ChatConversations,
    ChatMessage,
    ChatMessages
  }

  alias Elektrine.Social.Message

  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Moderation
  alias Elektrine.Messaging.Reactions
  alias Elektrine.Messaging.Servers
  alias Elektrine.Social.Conversations
  alias Elektrine.Social.Messages

  ## Conversations - Delegate to Conversations context

  @doc """
  Returns the list of conversations for a user.
  """
  defdelegate list_conversations(user_id, opts \\ []), to: Conversations

  defdelegate list_chat_conversations(user_id, opts \\ []),
    to: ChatConversations,
    as: :list_conversations

  @doc """
  Gets a single conversation with members and recent messages.
  """
  def get_conversation!(id, user_id) do
    if chat_conversation_type?(id) do
      ChatConversations.get_conversation!(id, user_id)
    else
      Conversations.get_conversation!(id, user_id)
    end
  end

  defdelegate get_chat_conversation!(id, user_id), to: ChatConversations, as: :get_conversation!

  @doc """
  Gets a conversation for chat display without preloading messages.
  Lightweight version optimized for chat view where messages are loaded separately.
  """
  defdelegate get_conversation_for_chat!(id, user_id), to: ChatConversations

  @doc """
  Gets a conversation by its hash.
  """
  defdelegate get_conversation_by_hash(hash), to: ChatConversations

  @doc """
  Gets a conversation for chat display by hash, ensuring user membership.
  """
  defdelegate get_conversation_for_chat_by_hash!(hash, user_id), to: ChatConversations

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
  defdelegate create_dm_conversation(user1_id, user2_id), to: ChatConversations

  @doc """
  Creates or gets a direct message conversation with a remote `user@domain` handle.
  """
  defdelegate create_remote_dm_conversation(local_user_id, remote_handle, attrs \\ %{}),
    to: ChatConversations

  @doc """
  Returns true when a conversation is a federated remote DM.
  """
  defdelegate remote_dm_conversation?(conversation), to: ChatConversations

  @doc """
  Returns normalized remote DM handle for a federated DM conversation.
  """
  defdelegate remote_dm_handle(conversation), to: ChatConversations

  @doc """
  Checks if user can create more conversations of the given type.
  """
  defdelegate check_creation_limit(user_id, type), to: ChatConversations

  @doc """
  Creates a group conversation.
  """
  defdelegate create_group_conversation(creator_id, attrs, member_ids \\ []), to: Conversations

  @doc """
  Creates a chat group conversation.
  """
  defdelegate create_chat_group_conversation(creator_id, attrs, member_ids \\ []),
    to: ChatConversations,
    as: :create_group_conversation

  @doc """
  Creates a channel.
  """
  defdelegate create_channel(creator_id, attrs), to: ChatConversations

  @doc """
  Updates a conversation (name, description, etc.).
  """
  def update_conversation(%ChatConversation{} = conversation, attrs),
    do: ChatConversations.update_conversation(conversation, attrs)

  def update_conversation(conversation, attrs),
    do: Conversations.update_conversation(conversation, attrs)

  @doc """
  Deletes a conversation (admin/creator only).
  """
  def delete_conversation(conversation_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.delete_conversation(conversation_id)
    else
      Conversations.delete_conversation(conversation_id)
    end
  end

  @doc """
  Lists public channels.
  """
  defdelegate list_public_channels(opts \\ []), to: ChatConversations

  @doc """
  Lists public groups.
  """
  defdelegate list_public_groups(opts \\ []), to: Conversations
  defdelegate list_chat_public_groups(opts \\ []), to: ChatConversations, as: :list_public_groups

  @doc """
  Searches for public groups and channels that the user can join.
  """
  defdelegate search_public_conversations(query, current_user_id, limit \\ 10), to: Conversations

  defdelegate search_public_chat_conversations(query, current_user_id, limit \\ 10),
    to: ChatConversations,
    as: :search_public_conversations

  @doc """
  Adds a member to a conversation.
  """
  def add_member_to_conversation(
        conversation_id,
        user_id,
        role \\ "member",
        added_by_user_id \\ nil
      ) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.add_member_to_conversation(
        conversation_id,
        user_id,
        role,
        added_by_user_id
      )
    else
      Conversations.add_member_to_conversation(conversation_id, user_id, role, added_by_user_id)
    end
  end

  @doc """
  Removes a member from a conversation.
  """
  def remove_member_from_conversation(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.remove_member_from_conversation(conversation_id, user_id)
    else
      Conversations.remove_member_from_conversation(conversation_id, user_id)
    end
  end

  @doc """
  Gets a conversation member record.
  """
  def get_conversation_member(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.get_conversation_member(conversation_id, user_id)
    else
      Conversations.get_conversation_member(conversation_id, user_id)
    end
  end

  @doc """
  Gets all members of a conversation.
  """
  def get_conversation_members(conversation_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.get_conversation_members(conversation_id)
    else
      Conversations.get_conversation_members(conversation_id)
    end
  end

  @doc """
  Lists pending remote join requests for a locally authoritative channel.
  """
  def list_pending_remote_join_requests(conversation_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.list_pending_remote_join_requests(conversation_id)
    else
      Conversations.list_pending_remote_join_requests(conversation_id)
    end
  end

  @doc """
  Approves a pending remote join request.
  """
  def approve_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.approve_remote_join_request(
        conversation_id,
        remote_actor_id,
        reviewer_user_id
      )
    else
      Conversations.approve_remote_join_request(
        conversation_id,
        remote_actor_id,
        reviewer_user_id
      )
    end
  end

  @doc """
  Declines a pending remote join request.
  """
  def decline_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.decline_remote_join_request(
        conversation_id,
        remote_actor_id,
        reviewer_user_id
      )
    else
      Conversations.decline_remote_join_request(
        conversation_id,
        remote_actor_id,
        reviewer_user_id
      )
    end
  end

  @doc """
  Promotes a member to admin role.
  """
  def promote_to_admin(conversation_id, user_id, promoter_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.promote_to_admin(conversation_id, user_id, promoter_id)
    else
      Conversations.promote_to_admin(conversation_id, user_id, promoter_id)
    end
  end

  @doc """
  Demotes an admin to regular member.
  """
  def demote_from_admin(conversation_id, user_id, demoter_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.demote_from_admin(conversation_id, user_id, demoter_id)
    else
      Conversations.demote_from_admin(conversation_id, user_id, demoter_id)
    end
  end

  @doc """
  Updates a member's role in a conversation.
  """
  def update_member_role(conversation_id, user_id, new_role) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.update_member_role(conversation_id, user_id, new_role)
    else
      Conversations.update_member_role(conversation_id, user_id, new_role)
    end
  end

  def update_member_role(conversation_id, user_id, new_role, actor_user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.update_member_role(conversation_id, user_id, new_role, actor_user_id)
    else
      Conversations.update_member_role(conversation_id, user_id, new_role, actor_user_id)
    end
  end

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
  def join_conversation(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.join_conversation(conversation_id, user_id)
    else
      Conversations.join_conversation(conversation_id, user_id)
    end
  end

  @doc """
  Joins a public channel.
  """
  defdelegate join_channel(channel_id, user_id), to: ChatConversations

  @doc """
  Pins a conversation for a user.
  """
  def pin_conversation(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.pin_conversation(conversation_id, user_id)
    else
      Conversations.pin_conversation(conversation_id, user_id)
    end
  end

  @doc """
  Unpins a conversation for a user.
  """
  def unpin_conversation(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.unpin_conversation(conversation_id, user_id)
    else
      Conversations.unpin_conversation(conversation_id, user_id)
    end
  end

  @doc """
  Allows a user to leave a conversation.
  """
  def leave_conversation(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatConversations.leave_conversation(conversation_id, user_id)
    else
      Conversations.leave_conversation(conversation_id, user_id)
    end
  end

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
  defdelegate user_has_conversations?(user_id), to: ChatConversations

  ## Servers - Delegate to Servers context

  @doc """
  Lists servers where the user is an active member.
  """
  defdelegate list_servers(user_id, opts \\ []), to: Servers

  @doc """
  Lists federated remote presence states for a server.
  """
  defdelegate list_server_presence_states(server_id), to: Federation

  @doc """
  Lists federated remote presence states visible to a specific local user in a server.
  """
  defdelegate list_visible_server_presence_states(server_id, user_id), to: Federation
  defdelegate list_room_presence_states(conversation_id), to: Federation
  defdelegate list_visible_room_presence_states(conversation_id, user_id), to: Federation

  @doc """
  Lists public servers the user can discover and join.
  """
  defdelegate list_public_servers(user_id, opts \\ []), to: Servers

  @doc """
  Lists local public servers for federation directory export.
  """
  defdelegate list_public_directory_servers(opts \\ []), to: Servers

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
  def create_text_message(conversation_id, sender_id, content, reply_to_id \\ nil, opts \\ []) do
    if chat_conversation_type?(conversation_id) do
      chat_opts =
        if is_nil(reply_to_id),
          do: opts,
          else: Keyword.put(opts, :reply_to_id, reply_to_id)

      ChatMessages.create_text_message(conversation_id, sender_id, content, chat_opts)
    else
      Messages.create_text_message(conversation_id, sender_id, content, reply_to_id, opts)
    end
  end

  @doc """
  Creates a media message in a conversation.
  """
  def create_media_message(
        conversation_id,
        sender_id,
        media_urls,
        content \\ nil,
        media_metadata \\ %{}
      ) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.create_media_message(
        conversation_id,
        sender_id,
        media_urls,
        content,
        media_metadata
      )
    else
      Messages.create_media_message(
        conversation_id,
        sender_id,
        media_urls,
        content,
        media_metadata
      )
    end
  end

  @doc """
  Creates a voice message in a conversation.
  """
  def create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.create_voice_message(
        conversation_id,
        sender_id,
        audio_url,
        duration,
        mime_type
      )
    else
      Messages.create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type)
    end
  end

  @doc """
  Creates a system message in a conversation.
  """
  def create_system_message(conversation_id, content, metadata \\ %{}) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.create_system_message(conversation_id, content)
    else
      Messages.create_system_message(conversation_id, content, metadata)
    end
  end

  @doc """
  Edits a message.
  """
  def edit_message(message_id, user_id, new_content) when is_integer(message_id) do
    if Repo.get(ChatMessage, message_id) do
      ChatMessages.edit_message(message_id, user_id, new_content)
    else
      Messages.edit_message(message_id, user_id, new_content)
    end
  end

  @doc """
  Deletes a message.
  """
  def delete_message(message_id, user_id, is_admin \\ false) when is_integer(message_id) do
    if Repo.get(ChatMessage, message_id) do
      ChatMessages.delete_message(message_id, user_id, is_admin)
    else
      Messages.delete_message(message_id, user_id, is_admin)
    end
  end

  @doc """
  Admin deletes a message (bypasses ownership check).
  """
  def admin_delete_message(message_id, %User{} = admin_user) when is_integer(message_id) do
    cond do
      not admin_user.is_admin ->
        {:error, :unauthorized}

      chat_message = Repo.get(ChatMessage, message_id) ->
        if chat_message.deleted_at do
          {:error, :already_deleted}
        else
          ChatMessages.delete_message(message_id, admin_user.id, true)
        end

      message = Repo.get(Message, message_id) ->
        if message.deleted_at do
          {:error, :already_deleted}
        else
          Messages.delete_message(message_id, admin_user.id, true)
        end

      true ->
        {:error, :not_found}
    end
  end

  @doc """
  Get messages for a conversation with pagination support.
  """
  def get_conversation_messages(conversation_id, user_id, opts \\ []) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.get_conversation_messages(conversation_id, user_id, opts)
    else
      Messages.get_conversation_messages(conversation_id, user_id, opts)
    end
  end

  @doc """
  Gets messages for a conversation with pagination.
  """
  def get_messages(conversation_id, user_id, opts \\ []) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        if chat_conversation_type?(conversation_id) do
          messages =
            ChatMessages.get_messages(conversation_id, Keyword.put(opts, :user_id, user_id))

          {:ok, messages}
        else
          Messages.get_messages(conversation_id, user_id, opts)
        end
    end
  end

  @doc """
  Searches messages within a specific conversation.
  """
  def search_messages_in_conversation(conversation_id, user_id, query, opts \\ []) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        if chat_conversation_type?(conversation_id) do
          {:ok,
           ChatMessages.search_messages(
             conversation_id,
             query,
             Keyword.put(opts, :user_id, user_id)
           )}
        else
          Messages.search_messages_in_conversation(conversation_id, user_id, query, opts)
        end
    end
  end

  @doc """
  Marks messages as read for a user in a conversation.
  """
  def mark_as_read(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      latest_message_id =
        ChatMessages.get_messages(conversation_id, limit: 1, user_id: user_id)
        |> case do
          [%{id: id} | _] -> id
          _ -> nil
        end

      case ChatMessages.update_last_read_message(conversation_id, user_id, latest_message_id) do
        {:ok, _} -> {:ok, :read}
        error -> error
      end
    else
      Messages.mark_as_read(conversation_id, user_id)
    end
  end

  @doc """
  Updates the last read message for a user in a conversation.
  """
  def update_last_read_message(conversation_id, user_id, message_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.update_last_read_message(conversation_id, user_id, message_id)
    else
      Messages.update_last_read_message(conversation_id, user_id, message_id)
    end
  end

  @doc """
  Gets the last read message ID for a user in a conversation.
  """
  def get_last_read_message_id(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.get_last_read_message_id(conversation_id, user_id)
    else
      Messages.get_last_read_message_id(conversation_id, user_id)
    end
  end

  @doc """
  Clears message history for a specific user.
  """
  def clear_history_for_user(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.clear_history_for_user(conversation_id, user_id)
    else
      Messages.clear_history_for_user(conversation_id, user_id)
    end
  end

  @doc """
  Gets users who have read a specific message.
  """
  def get_message_readers(message_id, conversation_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.get_message_readers(message_id, conversation_id)
    else
      Messages.get_message_readers(message_id, conversation_id)
    end
  end

  @doc """
  Gets read status for messages in a conversation.
  """
  def get_read_status_for_messages(message_ids, conversation_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.get_read_status_for_messages(message_ids, conversation_id)
    else
      Messages.get_read_status_for_messages(message_ids, conversation_id)
    end
  end

  @doc """
  Gets read status for last messages across multiple conversations in a batch.
  """
  def get_batch_last_message_read_status(message_info_list) do
    if message_info_list == [] do
      %{}
    else
      conversation_ids =
        message_info_list |> Enum.map(fn {conversation_id, _, _} -> conversation_id end)

      conversation_type_map = conversation_type_map(conversation_ids)

      {chat_info, non_chat_info} =
        Enum.split_with(message_info_list, fn {conversation_id, _message_id, _inserted_at} ->
          Map.get(conversation_type_map, conversation_id) in ["dm", "group", "channel"]
        end)

      chat_result = ChatMessages.get_batch_last_message_read_status(chat_info)
      non_chat_result = Messages.get_batch_last_message_read_status(non_chat_info)

      Map.merge(non_chat_result, chat_result)
    end
  end

  @doc """
  Gets unread message count for a specific conversation and user.
  """
  def get_conversation_unread_count(conversation_id, user_id) do
    if chat_conversation_type?(conversation_id) do
      ChatMessages.get_unread_count(conversation_id, user_id)
    else
      Messages.get_conversation_unread_count(conversation_id, user_id)
    end
  end

  @doc """
  Gets unread message counts for multiple conversations in a single query.
  Returns a map of conversation_id => unread_count.
  """
  def get_conversation_unread_counts(conversation_ids, user_id) do
    if conversation_ids == [] do
      %{}
    else
      type_map = conversation_type_map(conversation_ids)

      {chat_ids, non_chat_ids} =
        conversation_ids
        |> Enum.uniq()
        |> Enum.split_with(fn conversation_id ->
          Map.get(type_map, conversation_id) in ["dm", "group", "channel"]
        end)

      chat_counts = ChatMessages.get_conversation_unread_counts(chat_ids, user_id)
      non_chat_counts = Messages.get_conversation_unread_counts(non_chat_ids, user_id)

      Map.merge(non_chat_counts, chat_counts)
    end
  end

  @doc """
  Gets unread message count for a user across all conversations.
  """
  def get_unread_count(user_id) do
    ChatMessages.get_total_unread_count(user_id)
  end

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
  def timeout_user(conversation_id, user_id, created_by_id, duration_seconds)
      when is_integer(conversation_id) and is_integer(user_id) and is_integer(created_by_id) and
             is_integer(duration_seconds) do
    if chat_conversation_type?(conversation_id) do
      Moderation.timeout_chat_user(conversation_id, user_id, created_by_id, duration_seconds)
    else
      Moderation.timeout_user(user_id, created_by_id, duration_seconds,
        conversation_id: conversation_id
      )
    end
  end

  def timeout_user(user_id, created_by_id, duration_seconds, opts)
      when is_integer(user_id) and is_integer(created_by_id) and is_integer(duration_seconds) and
             is_list(opts) do
    Moderation.timeout_user(user_id, created_by_id, duration_seconds, opts)
  end

  @doc """
  Checks if a user is currently timed out in a conversation or globally.
  """
  defdelegate user_timed_out?(user_id, conversation_id \\ nil), to: Moderation

  @doc """
  Removes timeout for a user.
  """
  def remove_timeout(user_id, conversation_id \\ nil)

  def remove_timeout(conversation_id, user_id)
      when is_integer(conversation_id) and is_integer(user_id) do
    if chat_conversation_type?(conversation_id) do
      Moderation.remove_chat_timeout(conversation_id, user_id)
    else
      Moderation.remove_timeout(conversation_id, user_id)
    end
  end

  def remove_timeout(user_id, conversation_id),
    do: Moderation.remove_timeout(user_id, conversation_id)

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

  defp chat_conversation_type?(conversation_id) when is_integer(conversation_id) do
    case conversation_type(conversation_id) do
      "dm" -> true
      "group" -> true
      "channel" -> true
      _ -> false
    end
  end

  defp chat_conversation_type?(_), do: false

  defp conversation_type(conversation_id) do
    from(c in ChatConversation,
      where: c.id == ^conversation_id,
      select: c.type
    )
    |> Repo.one()
  end

  defp conversation_type_map(conversation_ids) when is_list(conversation_ids) do
    conversation_ids = Enum.uniq(conversation_ids)

    from(c in ChatConversation,
      where: c.id in ^conversation_ids,
      select: {c.id, c.type}
    )
    |> Repo.all()
    |> Map.new()
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
  def create_federated_like(message_id, remote_actor_id, activitypub_id \\ nil) do
    Messages.create_federated_like(message_id, remote_actor_id, activitypub_id)
  end

  @doc """
  Deletes a like from a federated source.
  """
  defdelegate delete_federated_like(message_id, remote_actor_id), to: Messages

  @doc """
  Creates a dislike (downvote) from a federated source.
  """
  def create_federated_dislike(message_id, remote_actor_id, activitypub_id \\ nil) do
    Messages.create_federated_dislike(message_id, remote_actor_id, activitypub_id)
  end

  @doc """
  Deletes a dislike from a federated source.
  """
  defdelegate delete_federated_dislike(message_id, remote_actor_id), to: Messages

  @doc """
  Creates a boost (announce) record from a federated source.
  """
  def create_federated_boost(message_id, remote_actor_id, activitypub_id \\ nil) do
    Messages.create_federated_boost(message_id, remote_actor_id, activitypub_id)
  end

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
