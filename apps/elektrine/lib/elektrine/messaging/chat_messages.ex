defmodule Elektrine.Messaging.ChatMessages do
  @moduledoc """
  Context for chat message operations.

  Handles DMs, group chats, and channel messages.
  Separate from timeline posts and community discussions.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    ChatMessage,
    ChatMessageReaction,
    ChatUserHiddenMessage,
    Conversation,
    ConversationMember,
    Conversations,
    Federation,
    FederationReadCursor
  }

  alias Elektrine.PubSubTopics

  @mention_pattern ~r/(?:^|[^A-Za-z0-9_])@([A-Za-z0-9_]{1,30})/

  # Message fetching

  @doc """
  Gets messages for a conversation with pagination.
  """
  def get_messages(conversation_id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    after_id = Keyword.get(opts, :after_id)
    decrypt? = Keyword.get(opts, :decrypt, true)

    messages =
      query_paginated_messages(conversation_id,
        user_id: user_id,
        limit: limit,
        before_id: before_id,
        after_id: after_id,
        decrypt?: decrypt?
      )

    Enum.reverse(messages)
  end

  @doc """
  Gets messages for a conversation with pagination metadata.
  Returns messages in reverse chronological order (newest first).
  """
  def get_conversation_messages(conversation_id, user_id, opts \\ []) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        %{
          messages: [],
          has_more_older: false,
          has_more_newer: false,
          oldest_id: nil,
          newest_id: nil
        }

      _member ->
        limit = Keyword.get(opts, :limit, 50)
        before_id = Keyword.get(opts, :before_id)
        after_id = Keyword.get(opts, :after_id)

        messages_desc =
          query_paginated_messages(conversation_id,
            user_id: user_id,
            limit: limit,
            before_id: before_id,
            after_id: after_id,
            decrypt?: true
          )

        has_more_older =
          has_more_older_messages?(conversation_id, user_id, messages_desc, before_id, after_id)

        has_more_newer =
          has_more_newer_messages?(conversation_id, user_id, messages_desc, after_id)

        oldest_id =
          case messages_desc do
            [] -> nil
            _ -> List.last(messages_desc).id
          end

        newest_id =
          case messages_desc do
            [%{id: id} | _] -> id
            [] -> nil
          end

        %{
          messages: messages_desc,
          has_more_older: has_more_older,
          has_more_newer: has_more_newer,
          oldest_id: oldest_id,
          newest_id: newest_id
        }
    end
  end

  defp query_paginated_messages(conversation_id, opts) do
    user_id = Keyword.get(opts, :user_id)
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    after_id = Keyword.get(opts, :after_id)
    decrypt? = Keyword.get(opts, :decrypt?, true)

    base_query =
      from(m in ChatMessage,
        left_join: h in ChatUserHiddenMessage,
        on: h.chat_message_id == m.id and h.user_id == ^user_id,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at) and is_nil(h.id),
        limit: ^limit,
        preload: [:sender, reply_to: [:sender], reactions: [:user, :remote_actor]]
      )

    query =
      cond do
        before_id ->
          from(m in base_query, where: m.id < ^before_id, order_by: [desc: m.inserted_at])

        after_id ->
          from(m in base_query, where: m.id > ^after_id, order_by: [asc: m.inserted_at])

        true ->
          from(m in base_query, order_by: [desc: m.inserted_at])
      end

    messages = Repo.all(query)
    messages = if after_id, do: Enum.reverse(messages), else: messages

    if decrypt? do
      messages
      |> ChatMessage.decrypt_messages()
      |> hydrate_remote_senders()
    else
      hydrate_remote_senders(messages)
    end
  end

  defp has_more_older_messages?(conversation_id, user_id, messages_desc, before_id, after_id) do
    if before_id || (!before_id && !after_id) do
      case List.last(messages_desc) do
        nil ->
          false

        oldest_message ->
          from(m in ChatMessage,
            left_join: h in ChatUserHiddenMessage,
            on: h.chat_message_id == m.id and h.user_id == ^user_id,
            where:
              m.conversation_id == ^conversation_id and
                m.id < ^oldest_message.id and
                is_nil(m.deleted_at) and
                is_nil(h.id),
            select: m.id,
            limit: 1
          )
          |> Repo.one()
          |> case do
            nil -> false
            _ -> true
          end
      end
    else
      false
    end
  end

  defp has_more_newer_messages?(conversation_id, user_id, messages_desc, after_id) do
    if after_id do
      case List.first(messages_desc) do
        nil ->
          false

        newest_message ->
          from(m in ChatMessage,
            left_join: h in ChatUserHiddenMessage,
            on: h.chat_message_id == m.id and h.user_id == ^user_id,
            where:
              m.conversation_id == ^conversation_id and
                m.id > ^newest_message.id and
                is_nil(m.deleted_at) and
                is_nil(h.id),
            select: m.id,
            limit: 1
          )
          |> Repo.one()
          |> case do
            nil -> false
            _ -> true
          end
      end
    else
      false
    end
  end

  defp get_conversation_member(conversation_id, user_id) when is_integer(user_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^conversation_id and
          cm.user_id == ^user_id and
          is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  defp get_conversation_member(_conversation_id, _user_id), do: nil

  @doc """
  Gets a single message by ID.
  """
  def get_message(id) do
    Repo.get(ChatMessage, id)
    |> Repo.preload([:sender, reply_to: [:sender], reactions: [:user, :remote_actor]])
    |> hydrate_remote_sender()
  end

  @doc """
  Gets a message and decrypts it.
  """
  def get_message_decrypted(id) do
    case get_message(id) do
      nil -> nil
      message -> message |> ChatMessage.decrypt_content() |> hydrate_remote_sender()
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
        reaction = Repo.preload(reaction, [:user, :remote_actor])
        broadcast_reaction_added(message_id, reaction)
        maybe_federate_reaction_added(message_id, reaction)
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
        maybe_federate_reaction_removed(message_id, user_id, emoji)
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
      preload: [:user, :remote_actor]
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
        left_join: h in ChatUserHiddenMessage,
        on: h.chat_message_id == m.id and h.user_id == ^user_id,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at) and is_nil(h.id),
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

    if entries != [] do
      Repo.insert_all("chat_message_reads", entries, on_conflict: :nothing)
    end

    latest_read_message_id = Enum.max(message_ids, fn -> nil end)

    if is_integer(latest_read_message_id) do
      Federation.publish_read_receipt(conversation_id, user_id, latest_read_message_id, now)
    end

    # Update conversation member's last_read_at
    from(cm in ConversationMember,
      where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
    )
    |> Repo.update_all(set: [last_read_at: now, last_read_message_id: nil])

    # Invalidate chat cache for this user
    Elektrine.AppCache.invalidate_chat_cache(user_id)

    :ok
  end

  @doc """
  Gets unread message count for a user in a conversation.
  """
  def get_unread_count(conversation_id, user_id) do
    from(m in ChatMessage,
      left_join: h in ChatUserHiddenMessage,
      on: h.chat_message_id == m.id and h.user_id == ^user_id,
      left_join: r in "chat_message_reads",
      on: field(r, :chat_message_id) == m.id and field(r, :user_id) == ^user_id,
      where:
        m.conversation_id == ^conversation_id and
          is_nil(h.id) and
          is_nil(m.deleted_at) and
          m.sender_id != ^user_id and
          is_nil(field(r, :chat_message_id)),
      select: count(m.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets unread counts for all of a user's conversations.
  """
  def get_all_unread_counts(user_id) do
    from(cm in ConversationMember,
      join: c in Conversation,
      on: c.id == cm.conversation_id,
      join: m in ChatMessage,
      on: m.conversation_id == cm.conversation_id,
      left_join: h in ChatUserHiddenMessage,
      on: h.chat_message_id == m.id and h.user_id == ^user_id,
      left_join: r in "chat_message_reads",
      on: field(r, :chat_message_id) == m.id and field(r, :user_id) == ^user_id,
      where:
        cm.user_id == ^user_id and
          is_nil(cm.left_at) and
          c.type in ["dm", "group", "channel"] and
          is_nil(h.id) and
          is_nil(m.deleted_at) and
          m.sender_id != ^user_id and
          is_nil(field(r, :chat_message_id)),
      group_by: cm.conversation_id,
      select: {cm.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Gets unread counts for a specific set of conversation IDs.
  """
  def get_conversation_unread_counts(conversation_ids, user_id) when is_list(conversation_ids) do
    conversation_ids
    |> Enum.uniq()
    |> Enum.map(fn conversation_id ->
      {conversation_id, get_unread_count(conversation_id, user_id)}
    end)
    |> Map.new()
  end

  @doc """
  Gets total unread chat count across DM/group/channel conversations.
  """
  def get_total_unread_count(user_id) do
    user_id
    |> get_all_unread_counts()
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Updates last read state up to a specific chat message.
  """
  def update_last_read_message(conversation_id, user_id, message_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        :ok = mark_messages_read(conversation_id, user_id, message_id)
        {:ok, :updated}
    end
  end

  @doc """
  Gets the last read message ID for a conversation member.
  """
  def get_last_read_message_id(conversation_id, user_id) do
    from(r in "chat_message_reads",
      join: m in ChatMessage,
      on: m.id == r.chat_message_id,
      left_join: h in ChatUserHiddenMessage,
      on: h.chat_message_id == m.id and h.user_id == ^user_id,
      where:
        r.user_id == ^user_id and
          m.conversation_id == ^conversation_id and
          is_nil(m.deleted_at) and
          is_nil(h.id),
      select: max(r.chat_message_id)
    )
    |> Repo.one()
  end

  @doc """
  Hides all current chat messages in a conversation for a specific user.
  """
  def clear_history_for_user(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        message_ids =
          from(m in ChatMessage,
            where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
            select: m.id
          )
          |> Repo.all()

        now = DateTime.utc_now() |> DateTime.truncate(:second)
        inserted_at = DateTime.to_naive(now)

        hidden_records =
          Enum.map(message_ids, fn message_id ->
            %{
              user_id: user_id,
              chat_message_id: message_id,
              hidden_at: now,
              inserted_at: inserted_at,
              updated_at: inserted_at
            }
          end)

        if hidden_records != [] do
          Repo.insert_all(ChatUserHiddenMessage, hidden_records, on_conflict: :nothing)
        end

        from(cm in ConversationMember,
          where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
        )
        |> Repo.update_all(set: [last_read_at: now, last_read_message_id: nil])

        Elektrine.AppCache.invalidate_chat_cache(user_id)

        {:ok, :cleared}
    end
  end

  @doc """
  Gets users who have read a specific chat message.
  """
  def get_message_readers(message_id, conversation_id) do
    sender_id =
      from(m in ChatMessage,
        where: m.id == ^message_id and m.conversation_id == ^conversation_id,
        select: m.sender_id
      )
      |> Repo.one()

    local_readers =
      from(r in "chat_message_reads",
        join: u in Elektrine.Accounts.User,
        on: u.id == r.user_id,
        where:
          r.chat_message_id == ^message_id and
            (is_nil(^sender_id) or r.user_id != ^sender_id),
        select: %{user_id: u.id, username: u.username, avatar: u.avatar, read_at: r.read_at}
      )
      |> Repo.all()

    remote_readers =
      from(rr in FederationReadCursor,
        join: actor in ActivityPubActor,
        on: actor.id == rr.remote_actor_id,
        where:
          rr.conversation_id == ^conversation_id and
            rr.chat_message_id >= ^message_id,
        select: %{
          user_id: nil,
          remote_actor_id: actor.id,
          username: actor.username,
          display_name: actor.display_name,
          domain: actor.domain,
          avatar: actor.avatar_url,
          read_at: rr.read_at
        }
      )
      |> Repo.all()
      |> Enum.map(fn reader ->
        %{
          user_id: nil,
          remote_actor_id: reader.remote_actor_id,
          username: remote_reader_label(reader),
          avatar: reader.avatar,
          read_at: reader.read_at
        }
      end)

    dedupe_readers(local_readers ++ remote_readers)
  end

  @doc """
  Gets read status for chat messages in a conversation.
  """
  def get_read_status_for_messages(message_ids, conversation_id) when is_list(message_ids) do
    if message_ids == [] do
      %{}
    else
      messages =
        from(m in ChatMessage,
          where: m.id in ^message_ids and m.conversation_id == ^conversation_id,
          select: %{id: m.id, sender_id: m.sender_id}
        )
        |> Repo.all()

      message_sender_map = Map.new(messages, &{&1.id, &1.sender_id})

      reads_by_message =
        from(r in "chat_message_reads",
          join: u in Elektrine.Accounts.User,
          on: u.id == r.user_id,
          where: r.chat_message_id in ^message_ids,
          select: %{
            message_id: r.chat_message_id,
            user_id: u.id,
            username: u.username,
            avatar: u.avatar
          }
        )
        |> Repo.all()
        |> Enum.group_by(& &1.message_id)

      remote_read_cursors =
        from(rr in FederationReadCursor,
          join: actor in ActivityPubActor,
          on: actor.id == rr.remote_actor_id,
          where: rr.conversation_id == ^conversation_id,
          select: %{
            read_through_message_id: rr.chat_message_id,
            user_id: nil,
            remote_actor_id: actor.id,
            username: actor.username,
            display_name: actor.display_name,
            domain: actor.domain,
            avatar: actor.avatar_url
          }
        )
        |> Repo.all()
        |> Enum.map(fn reader ->
          %{
            read_through_message_id: reader.read_through_message_id,
            user_id: nil,
            remote_actor_id: reader.remote_actor_id,
            username: remote_reader_label(reader),
            avatar: reader.avatar
          }
        end)

      Enum.reduce(message_ids, %{}, fn message_id, acc ->
        sender_id = Map.get(message_sender_map, message_id)

        local_readers =
          reads_by_message
          |> Map.get(message_id, [])
          |> Enum.reject(fn reader -> reader.user_id == sender_id end)

        remote_readers =
          remote_read_cursors
          |> Enum.filter(&(&1.read_through_message_id >= message_id))
          |> Enum.map(fn reader ->
            %{
              user_id: nil,
              remote_actor_id: reader.remote_actor_id,
              username: reader.username,
              avatar: reader.avatar
            }
          end)

        readers = dedupe_readers(local_readers ++ remote_readers)

        Map.put(acc, message_id, readers)
      end)
    end
  end

  @doc """
  Gets read status for last messages across multiple conversations.
  """
  def get_batch_last_message_read_status(message_info_list) when is_list(message_info_list) do
    if message_info_list == [] do
      %{}
    else
      message_ids =
        Enum.map(message_info_list, fn {_conversation_id, message_id, _} -> message_id end)

      senders_by_message =
        from(m in ChatMessage,
          where: m.id in ^message_ids,
          select: {m.id, m.sender_id}
        )
        |> Repo.all()
        |> Map.new()

      reads_by_message =
        from(r in "chat_message_reads",
          where: r.chat_message_id in ^message_ids,
          select: {r.chat_message_id, r.user_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {message_id, _user_id} -> message_id end, fn {_message_id, user_id} ->
          user_id
        end)

      conversation_ids =
        message_info_list
        |> Enum.map(fn {conversation_id, _message_id, _inserted_at} -> conversation_id end)
        |> Enum.uniq()

      remote_read_cursors_by_conversation =
        from(rr in FederationReadCursor,
          where: rr.conversation_id in ^conversation_ids,
          select: {rr.conversation_id, rr.chat_message_id}
        )
        |> Repo.all()
        |> Enum.group_by(
          fn {conversation_id, _message_id} -> conversation_id end,
          fn {_conversation_id, message_id} ->
            message_id
          end
        )

      message_info_list
      |> Enum.map(fn {conversation_id, message_id, _inserted_at} ->
        sender_id = Map.get(senders_by_message, message_id)

        local_reader_count =
          reads_by_message
          |> Map.get(message_id, [])
          |> Enum.reject(&(&1 == sender_id))
          |> Enum.uniq()
          |> length()

        remote_reader_count =
          remote_read_cursors_by_conversation
          |> Map.get(conversation_id, [])
          |> Enum.count(&(&1 >= message_id))

        reader_count = local_reader_count + remote_reader_count

        {conversation_id, %{is_read: reader_count > 0, reader_count: reader_count}}
      end)
      |> Map.new()
    end
  end

  defp dedupe_readers(readers) when is_list(readers) do
    readers
    |> Enum.uniq_by(fn reader ->
      cond do
        is_integer(reader[:user_id]) -> {:user, reader[:user_id]}
        is_integer(reader[:remote_actor_id]) -> {:remote_actor, reader[:remote_actor_id]}
        true -> {:fallback, reader[:username], reader[:avatar]}
      end
    end)
  end

  defp dedupe_readers(_), do: []

  defp remote_reader_label(reader) when is_map(reader) do
    username = reader[:username] || reader["username"] || "remote"
    display_name = reader[:display_name] || reader["display_name"]
    domain = reader[:domain] || reader["domain"]
    handle = if is_binary(domain), do: "@#{username}@#{domain}", else: "@#{username}"

    if is_binary(display_name) and String.trim(display_name) != "" and display_name != username do
      "#{display_name} (#{handle})"
    else
      handle
    end
  end

  defp remote_reader_label(_), do: "@remote"

  # Search

  @doc """
  Searches messages in a conversation.
  Uses `search_index` tokens derived from plaintext chat content.
  """
  def search_messages(conversation_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    user_id = Keyword.get(opts, :user_id)

    keywords = Elektrine.Encryption.extract_keywords(query)

    if is_nil(user_id) or Enum.empty?(keywords) do
      []
    else
      keyword_hashes =
        Enum.map(keywords, fn keyword ->
          Elektrine.Encryption.hash_keyword(keyword, user_id)
        end)

      from(m in ChatMessage,
        left_join: h in ChatUserHiddenMessage,
        on: h.chat_message_id == m.id and h.user_id == ^user_id,
        where:
          m.conversation_id == ^conversation_id and
            is_nil(m.deleted_at) and
            is_nil(h.id) and
            fragment("? && ?", m.search_index, ^keyword_hashes),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [:sender, reactions: [:user, :remote_actor]]
      )
      |> Repo.all()
      |> ChatMessage.decrypt_messages()
      |> hydrate_remote_senders()
    end
  end

  # Private helpers

  # Chat content is stored in plaintext. Email encryption remains in Elektrine.Email.* modules.
  defp should_encrypt?(_conversation_id), do: false

  defp handle_message_created({:ok, message}, conversation_id) do
    # Preload associations
    message =
      Repo.preload(message, [:sender, reply_to: [:sender], reactions: [:user, :remote_actor]])

    # Decrypt for API response and broadcasting
    decrypted = message |> ChatMessage.decrypt_content() |> hydrate_remote_sender()

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
    maybe_federate_message_created(conversation_id, decrypted)
    maybe_notify_chat_members(conversation_id, decrypted)

    {:ok, decrypted}
  end

  defp handle_message_created(error, _conversation_id), do: error

  defp handle_message_updated({:ok, message}) do
    message =
      Repo.preload(message, [:sender, reply_to: [:sender], reactions: [:user, :remote_actor]])

    decrypted = message |> ChatMessage.decrypt_content() |> hydrate_remote_sender()

    broadcast_message_updated(decrypted.conversation_id, decrypted)
    maybe_federate_message_updated(decrypted)

    {:ok, decrypted}
  end

  defp handle_message_updated(error), do: error

  defp handle_message_deleted({:ok, message}) do
    broadcast_message_deleted(message.conversation_id, message.id)
    maybe_federate_message_deleted(message)
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

  defp maybe_federate_message_created(conversation_id, message) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{type: "channel", is_federated_mirror: true}
      when is_integer(message.sender_id) ->
        Federation.submit_mirror_message_created(message)

      %Conversation{type: "channel"} ->
        Federation.publish_message_created(message)

      %Conversation{type: "dm"} = conversation when is_integer(message.sender_id) ->
        case Conversations.remote_dm_handle(conversation) do
          handle when is_binary(handle) ->
            Federation.publish_dm_message_created(message, handle)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_federate_message_updated(message) do
    case Repo.get(Conversation, message.conversation_id) do
      %Conversation{type: "channel", is_federated_mirror: true}
      when is_integer(message.sender_id) ->
        Federation.submit_mirror_message_updated(message)

      %Conversation{type: "channel"} ->
        Federation.publish_message_updated(message)

      _ ->
        :ok
    end
  end

  defp maybe_federate_message_deleted(message) do
    case Repo.get(Conversation, message.conversation_id) do
      %Conversation{type: "channel", is_federated_mirror: true}
      when is_integer(message.sender_id) ->
        Federation.submit_mirror_message_deleted(message)

      %Conversation{type: "channel"} ->
        Federation.publish_message_deleted(message)

      _ ->
        :ok
    end
  end

  defp maybe_federate_reaction_added(message_id, reaction) do
    case get_message(message_id) do
      %ChatMessage{} = message ->
        case Repo.get(Conversation, message.conversation_id) do
          %Conversation{type: "channel", is_federated_mirror: true}
          when is_integer(reaction.user_id) ->
            Federation.submit_mirror_reaction_added(message, reaction)

          %Conversation{type: "channel"} ->
            Federation.publish_reaction_added(message, reaction)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_federate_reaction_removed(message_id, user_id, emoji) do
    case get_message(message_id) do
      %ChatMessage{} = message ->
        case Repo.get(Conversation, message.conversation_id) do
          %Conversation{type: "channel", is_federated_mirror: true} when is_integer(user_id) ->
            Federation.submit_mirror_reaction_removed(message, user_id, emoji)

          %Conversation{type: "channel"} ->
            Federation.publish_reaction_removed(message, user_id, emoji)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp hydrate_remote_senders(messages) when is_list(messages) do
    Enum.map(messages, &hydrate_remote_sender/1)
  end

  defp hydrate_remote_senders(_), do: []

  defp hydrate_remote_sender(nil), do: nil

  defp hydrate_remote_sender(%ChatMessage{} = message) do
    reply_to =
      case message.reply_to do
        %ChatMessage{} = reply -> hydrate_remote_sender(reply)
        other -> other
      end

    message = %{message | reply_to: reply_to}

    if is_nil(message.sender) do
      case remote_sender_from_metadata(message.media_metadata) do
        nil ->
          message

        remote_sender ->
          %{message | sender: remote_sender}
      end
    else
      message
    end
  end

  defp hydrate_remote_sender(message), do: message

  defp remote_sender_from_metadata(metadata) when is_map(metadata) do
    sender = metadata["remote_sender"] || metadata[:remote_sender]

    if is_map(sender) do
      username =
        sender["username"] || sender[:username] || sender["handle"] || sender[:handle] || "remote"

      display_name = sender["display_name"] || sender[:display_name] || username
      domain = sender["domain"] || sender[:domain]
      handle = sender["handle"] || sender[:handle] || remote_handle(username, domain)
      avatar = sender["avatar"] || sender[:avatar] || sender["avatar_url"] || sender[:avatar_url]

      %{
        id: nil,
        username: to_string(username),
        display_name: to_string(display_name),
        handle: to_string(handle),
        avatar: avatar,
        remote: true,
        remote_domain: domain
      }
    else
      nil
    end
  end

  defp remote_sender_from_metadata(_), do: nil

  defp remote_handle(username, domain) when is_binary(domain) and domain != "" do
    "#{username}@#{domain}"
  end

  defp remote_handle(username, _domain), do: to_string(username)

  defp maybe_notify_chat_members(conversation_id, %ChatMessage{sender_id: sender_id} = message)
       when is_integer(sender_id) do
    content = message.content || ChatMessage.display_content(message) || ""
    notify_chat_members(conversation_id, sender_id, content, message.id, message.reply_to_id)
  end

  defp maybe_notify_chat_members(_conversation_id, _message), do: :ok

  defp notify_chat_members(conversation_id, sender_id, content, message_id, reply_to_id) do
    sender = Accounts.get_user!(sender_id)

    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation ->
        original_sender_id =
          if reply_to_id do
            from(m in ChatMessage, where: m.id == ^reply_to_id, select: m.sender_id)
            |> Repo.one()
          end

        if original_sender_id && original_sender_id != sender_id do
          user = Accounts.get_user!(original_sender_id)

          if notification_preference_enabled?(user, :notify_on_reply) do
            Elektrine.Notifications.create_notification(%{
              user_id: original_sender_id,
              actor_id: sender_id,
              type: "reply",
              title: "New reply from @#{sender.handle || sender.username}",
              body:
                "@#{sender.handle || sender.username} replied to your message: #{String.slice(content, 0, 50)}#{if String.length(content) > 50, do: "...", else: ""}",
              url: "/chat/#{conversation_id}#message-#{message_id}",
              source_type: "message",
              source_id: message_id,
              priority: "normal"
            })
          end
        end

        members_with_preferences =
          from(cm in ConversationMember,
            join: u in Accounts.User,
            on: u.id == cm.user_id,
            where:
              cm.conversation_id == ^conversation_id and
                cm.user_id != ^sender_id and
                is_nil(cm.left_at),
            select: %{
              user_id: u.id,
              username: u.username,
              handle: u.handle,
              notify_on_direct_message: u.notify_on_direct_message
            }
          )
          |> Repo.all()

        Enum.each(members_with_preferences, fn member ->
          unless reply_to_id && member.user_id == original_sender_id do
            should_notify =
              case conversation.type do
                "dm" -> notification_preference_enabled?(member, :notify_on_direct_message)
                _ -> true
              end

            if should_notify do
              {title, message_text} =
                case conversation.type do
                  "dm" ->
                    {"Message from #{sender.username}",
                     "#{String.slice(content, 0, 100)}#{if String.length(content) > 100, do: "...", else: ""}"}

                  "group" ->
                    {"#{conversation.name || "Group"} message",
                     "#{sender.username}: #{String.slice(content, 0, 80)}#{if String.length(content) > 80, do: "...", else: ""}"}

                  "channel" ->
                    {"##{conversation.name || "channel"}",
                     "#{sender.username}: #{String.slice(content, 0, 80)}#{if String.length(content) > 80, do: "...", else: ""}"}

                  _ ->
                    {"New message", "From #{sender.username}"}
                end

              Elektrine.Notifications.create_notification(%{
                user_id: member.user_id,
                actor_id: sender_id,
                type: "new_message",
                title: title,
                body: message_text,
                url: "/chat/#{conversation_id}#message-#{message_id}",
                source_type: "message",
                source_id: message_id,
                priority: if(conversation.type == "dm", do: "normal", else: "low")
              })
            end
          end
        end)

        notify_mentions_in_chat(content, members_with_preferences, sender, sender_id, message_id)

      _ ->
        :ok
    end
  end

  defp notification_preference_enabled?(subject, field) when is_atom(field) do
    Map.get(subject, field) != false
  end

  defp notify_mentions_in_chat(content, members_with_preferences, sender, sender_id, message_id) do
    mentioned_user_ids =
      extract_mentioned_user_ids(content, members_with_preferences)
      |> Enum.reject(&(&1 == sender_id))

    context = mention_context(content)

    Enum.each(mentioned_user_ids, fn mentioned_user_id ->
      case Elektrine.Privacy.can_mention?(sender_id, mentioned_user_id) do
        {:ok, :allowed} ->
          Elektrine.Notifications.notify_mention(
            mentioned_user_id,
            sender,
            "message",
            message_id,
            context
          )

        _ ->
          :ok
      end
    end)
  end

  defp extract_mentioned_user_ids(content, members_with_preferences) when is_binary(content) do
    lookup =
      Enum.reduce(members_with_preferences, %{}, fn member, acc ->
        acc
        |> put_mention_lookup(member.username, member.user_id)
        |> put_mention_lookup(member.handle, member.user_id)
      end)

    Regex.scan(@mention_pattern, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn mention -> Map.get(lookup, mention, []) end)
    |> Enum.uniq()
  end

  defp extract_mentioned_user_ids(_, _), do: []

  defp put_mention_lookup(lookup, identifier, user_id) when is_binary(identifier) do
    key = String.downcase(identifier)
    Map.update(lookup, key, [user_id], &[user_id | &1])
  end

  defp put_mention_lookup(lookup, _identifier, _user_id), do: lookup

  defp mention_context(content) when is_binary(content) do
    snippet = String.trim(content) |> String.slice(0, 120)
    "Mentioned you in chat: #{snippet}"
  end

  defp mention_context(_), do: "Mentioned you in chat"
end
