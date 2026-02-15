defmodule Elektrine.Messaging.ChatMessages do
  @moduledoc """
  Context for chat message operations.

  Handles DMs, group chats, and channel messages.
  Separate from timeline posts and community discussions.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    ChatMessage,
    ChatMessageReaction,
    Conversation,
    ConversationMember,
    Federation
  }

  alias Elektrine.PubSubTopics

  # Message fetching

  @doc """
  Gets messages for a conversation with pagination.
  """
  def get_messages(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    decrypt? = Keyword.get(opts, :decrypt, true)

    query =
      from(m in ChatMessage,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [:sender, :reply_to, reactions: [:user]]
      )

    query =
      if before_id do
        from(m in query, where: m.id < ^before_id)
      else
        query
      end

    messages = Repo.all(query) |> Enum.reverse()

    if decrypt? do
      ChatMessage.decrypt_messages(messages)
    else
      messages
    end
  end

  @doc """
  Gets a single message by ID.
  """
  def get_message(id) do
    Repo.get(ChatMessage, id)
    |> Repo.preload([:sender, :reply_to, reactions: [:user]])
  end

  @doc """
  Gets a message and decrypts it.
  """
  def get_message_decrypted(id) do
    case get_message(id) do
      nil -> nil
      message -> ChatMessage.decrypt_content(message)
    end
  end

  # Message creation

  @doc """
  Creates a text message.
  """
  def create_text_message(conversation_id, sender_id, content, opts \\ []) do
    reply_to_id = Keyword.get(opts, :reply_to_id)
    encrypt? = should_encrypt?(conversation_id)

    ChatMessage.text_changeset(conversation_id, sender_id, content, reply_to_id, encrypt?)
    |> Repo.insert()
    |> handle_message_created(conversation_id)
  end

  @doc """
  Creates a media message (image or file).
  """
  def create_media_message(
        conversation_id,
        sender_id,
        media_urls,
        content \\ nil,
        media_metadata \\ %{}
      ) do
    encrypt? = should_encrypt?(conversation_id)

    ChatMessage.media_changeset(
      conversation_id,
      sender_id,
      media_urls,
      content,
      media_metadata,
      encrypt?
    )
    |> Repo.insert()
    |> handle_message_created(conversation_id)
  end

  @doc """
  Creates a voice message.
  """
  def create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type) do
    ChatMessage.voice_changeset(conversation_id, sender_id, audio_url, duration, mime_type)
    |> Repo.insert()
    |> handle_message_created(conversation_id)
  end

  @doc """
  Creates a system message.
  """
  def create_system_message(conversation_id, content) do
    ChatMessage.system_changeset(conversation_id, content)
    |> Repo.insert()
    |> handle_message_created(conversation_id)
  end

  # Message editing

  @doc """
  Edits a message.
  """
  def edit_message(message_id, user_id, new_content) do
    case get_message(message_id) do
      nil ->
        {:error, :not_found}

      message ->
        if ChatMessage.can_edit?(message, user_id) do
          encrypt? = should_encrypt?(message.conversation_id)

          message
          |> ChatMessage.edit_changeset(new_content, encrypt?)
          |> Repo.update()
          |> handle_message_updated()
        else
          {:error, :unauthorized}
        end
    end
  end

  # Message deletion

  @doc """
  Soft-deletes a message.
  """
  def delete_message(message_id, user_id, is_admin \\ false) do
    case get_message(message_id) do
      nil ->
        {:error, :not_found}

      message ->
        if ChatMessage.can_delete?(message, user_id, is_admin) do
          message
          |> ChatMessage.delete_changeset()
          |> Repo.update()
          |> handle_message_deleted()
        else
          {:error, :unauthorized}
        end
    end
  end

  # Reactions

  @doc """
  Adds a reaction to a message.
  """
  def add_reaction(message_id, user_id, emoji) do
    %ChatMessageReaction{}
    |> ChatMessageReaction.changeset(%{
      chat_message_id: message_id,
      user_id: user_id,
      emoji: emoji
    })
    |> Repo.insert()
    |> case do
      {:ok, reaction} ->
        broadcast_reaction_added(message_id, reaction)
        {:ok, reaction}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Removes a reaction from a message.
  """
  def remove_reaction(message_id, user_id, emoji) do
    from(r in ChatMessageReaction,
      where: r.chat_message_id == ^message_id and r.user_id == ^user_id and r.emoji == ^emoji
    )
    |> Repo.delete_all()
    |> case do
      {count, _} when count > 0 ->
        broadcast_reaction_removed(message_id, user_id, emoji)
        {:ok, count}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets all reactions for a message grouped by emoji.
  """
  def get_reactions(message_id) do
    from(r in ChatMessageReaction,
      where: r.chat_message_id == ^message_id,
      preload: [:user]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.emoji)
  end

  # Read receipts

  @doc """
  Marks messages as read up to a certain message.
  """
  def mark_messages_read(conversation_id, user_id, up_to_message_id \\ nil) do
    now = DateTime.utc_now()

    # Get message IDs to mark as read
    query =
      from(m in ChatMessage,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
        select: m.id
      )

    query =
      if up_to_message_id do
        from(m in query, where: m.id <= ^up_to_message_id)
      else
        query
      end

    message_ids = Repo.all(query)

    # Insert read receipts (ignore conflicts)
    entries =
      Enum.map(message_ids, fn msg_id ->
        %{chat_message_id: msg_id, user_id: user_id, read_at: now}
      end)

    Repo.insert_all("chat_message_reads", entries, on_conflict: :nothing)

    # Update conversation member's last_read_at
    from(cm in ConversationMember,
      where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
    )
    |> Repo.update_all(set: [last_read_at: now])

    # Invalidate chat cache for this user
    Elektrine.AppCache.invalidate_chat_cache(user_id)

    :ok
  end

  @doc """
  Gets unread message count for a user in a conversation.
  """
  def get_unread_count(conversation_id, user_id) do
    # Get user's last read timestamp
    last_read_at =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id,
        select: cm.last_read_at
      )
      |> Repo.one()

    query =
      from(m in ChatMessage,
        where:
          m.conversation_id == ^conversation_id and
            is_nil(m.deleted_at) and
            m.sender_id != ^user_id
      )

    query =
      if last_read_at do
        from(m in query, where: m.inserted_at > ^last_read_at)
      else
        query
      end

    Repo.aggregate(query, :count, :id)
  end

  @doc """
  Gets unread counts for all of a user's conversations.
  """
  def get_all_unread_counts(user_id) do
    # Get all conversations the user is a member of with their last_read_at
    conversation_reads =
      from(cm in ConversationMember,
        where: cm.user_id == ^user_id and is_nil(cm.left_at),
        join: c in Conversation,
        on: c.id == cm.conversation_id,
        where: c.type in ["dm", "group", "channel"],
        select: {cm.conversation_id, cm.last_read_at}
      )
      |> Repo.all()
      |> Map.new()

    conversation_ids = Map.keys(conversation_reads)

    # Count unread messages per conversation
    from(m in ChatMessage,
      where:
        m.conversation_id in ^conversation_ids and
          is_nil(m.deleted_at) and
          m.sender_id != ^user_id,
      group_by: m.conversation_id,
      select: {m.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {conv_id, total_count} ->
      last_read = Map.get(conversation_reads, conv_id)

      unread_count =
        if last_read do
          from(m in ChatMessage,
            where:
              m.conversation_id == ^conv_id and
                is_nil(m.deleted_at) and
                m.sender_id != ^user_id and
                m.inserted_at > ^last_read
          )
          |> Repo.aggregate(:count, :id)
        else
          total_count
        end

      {conv_id, unread_count}
    end)
    |> Map.new()
  end

  # Search

  @doc """
  Searches messages in a conversation.
  Note: For encrypted messages, search uses the search_index tokens.
  """
  def search_messages(conversation_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    # Create search tokens from query (same logic as indexing)
    search_tokens =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 2))

    from(m in ChatMessage,
      where:
        m.conversation_id == ^conversation_id and
          is_nil(m.deleted_at) and
          fragment("? && ?", m.search_index, ^search_tokens),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
    |> ChatMessage.decrypt_messages()
  end

  # Private helpers

  defp should_encrypt?(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> true
      %{type: type} -> type in ["dm", "group", "channel"]
    end
  end

  defp handle_message_created({:ok, message}, conversation_id) do
    # Preload associations
    message = Repo.preload(message, [:sender, :reply_to, reactions: [:user]])

    # Decrypt for API response and broadcasting
    decrypted = ChatMessage.decrypt_content(message)

    # Update conversation's last_message_at
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_at: message.inserted_at])

    # Invalidate chat cache for all conversation members
    member_ids =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: cm.user_id
      )
      |> Repo.all()

    Enum.each(member_ids, &Elektrine.AppCache.invalidate_chat_cache/1)

    # Broadcast to conversation
    broadcast_new_message(conversation_id, decrypted)
    Federation.publish_message_created(decrypted)

    {:ok, decrypted}
  end

  defp handle_message_created(error, _conversation_id), do: error

  defp handle_message_updated({:ok, message}) do
    message = Repo.preload(message, [:sender, :reply_to])
    decrypted = ChatMessage.decrypt_content(message)

    broadcast_message_updated(decrypted.conversation_id, decrypted)

    {:ok, decrypted}
  end

  defp handle_message_updated(error), do: error

  defp handle_message_deleted({:ok, message}) do
    broadcast_message_deleted(message.conversation_id, message.id)
    {:ok, message}
  end

  defp handle_message_deleted(error), do: error

  # PubSub broadcasts

  defp broadcast_new_message(conversation_id, message) do
    topic = PubSubTopics.conversation(conversation_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:new_chat_message, message})
  end

  defp broadcast_message_updated(conversation_id, message) do
    topic = PubSubTopics.conversation(conversation_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:chat_message_updated, message})
  end

  defp broadcast_message_deleted(conversation_id, message_id) do
    topic = PubSubTopics.conversation(conversation_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:chat_message_deleted, message_id})
  end

  defp broadcast_reaction_added(message_id, reaction) do
    message = get_message(message_id)

    if message do
      topic = PubSubTopics.conversation(message.conversation_id)

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        topic,
        {:chat_reaction_added, message_id, reaction}
      )
    end
  end

  defp broadcast_reaction_removed(message_id, user_id, emoji) do
    message = get_message(message_id)

    if message do
      topic = PubSubTopics.conversation(message.conversation_id)

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        topic,
        {:chat_reaction_removed, message_id, user_id, emoji}
      )
    end
  end
end
