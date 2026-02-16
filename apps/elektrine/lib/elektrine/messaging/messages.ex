defmodule Elektrine.Messaging.Messages do
  @moduledoc """
  Context for managing messages - creation, editing, deletion, and retrieval.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.Repo
  alias Elektrine.Accounts

  alias Elektrine.Messaging.{
    Conversation,
    ConversationMember,
    Message,
    UserHiddenMessage,
    RateLimiter
  }

  alias Elektrine.Social.{LinkPreviewFetcher, LinkPreview, FetchLinkPreviewWorker}
  @mention_pattern ~r/(?:^|[^A-Za-z0-9_])@([A-Za-z0-9_]{1,30})/

  @doc """
  Creates a text message in a conversation.
  """
  def create_text_message(conversation_id, sender_id, content, reply_to_id \\ nil, opts \\ []) do
    # Check rate limiting first (with fallback if rate limiter not running)
    can_send =
      try do
        RateLimiter.can_send_message?(sender_id)
      rescue
        # Fallback to allowing if rate limiter not available
        _ -> true
      catch
        # Fallback if process not alive
        :exit, _ -> true
      end

    if can_send do
      # Get conversation to check type and for privacy validation
      conversation = Repo.get(Conversation, conversation_id)

      # For DM conversations, check privacy settings
      privacy_check =
        if conversation && conversation.type == "dm" do
          # Get the other user in the DM
          other_user_id =
            from(cm in ConversationMember,
              where:
                cm.conversation_id == ^conversation_id and cm.user_id != ^sender_id and
                  is_nil(cm.left_at),
              select: cm.user_id,
              limit: 1
            )
            |> Repo.one()

          if other_user_id do
            Elektrine.Privacy.can_send_dm?(sender_id, other_user_id)
          else
            {:ok, :allowed}
          end
        else
          {:ok, :allowed}
        end

      case privacy_check do
        {:error, reason} ->
          {:error, reason}

        {:ok, :allowed} ->
          # Verify sender is a member of the conversation
          case get_conversation_member(conversation_id, sender_id) do
            nil ->
              {:error, :unauthorized}

            member ->
              if ConversationMember.can_send_messages?(member) do
                result =
                  Message.text_changeset(
                    conversation_id,
                    sender_id,
                    content,
                    reply_to_id,
                    conversation.type
                  )
                  |> Repo.insert()

                case result do
                  {:ok, message} ->
                    # Side-effect (link previews): skip in tests to avoid sandbox/network noise.
                    Elektrine.Async.start(fn -> extract_and_attach_link_preview(message) end)

                    # Update reply count if this is a reply
                    if reply_to_id do
                      from(m in Message,
                        where: m.id == ^reply_to_id,
                        update: [inc: [reply_count: 1]]
                      )
                      |> Repo.update_all([])
                    end

                    # Record for rate limiting (with fallback)
                    try do
                      RateLimiter.record_message(sender_id)
                    rescue
                      # Ignore if rate limiter not available
                      _ -> :ok
                    catch
                      # Ignore if process not alive
                      :exit, _ -> :ok
                    end

                    # Update conversation's last_message_at
                    update_conversation_timestamp(conversation_id)

                    # Create notifications for other conversation members
                    notify_conversation_members(
                      conversation_id,
                      sender_id,
                      content,
                      message.id,
                      reply_to_id
                    )

                    # Broadcast the message (unless explicitly skipped)
                    unless opts[:skip_broadcast] do
                      broadcast_message(message)
                    end

                    # Federate to ActivityPub (async)
                    if conversation.type == "timeline" &&
                         message.visibility in ["public", "followers"] do
                      Elektrine.Async.start(fn ->
                        preloaded = Repo.preload(message, :sender)
                        Elektrine.ActivityPub.Outbox.federate_post(preloaded)
                      end)
                    end

                    # Ensure link_preview is loaded (might be nil initially)
                    preloaded_message =
                      Repo.preload(message, [:sender, :reply_to, :reactions, :link_preview])

                    decrypted_message = Message.decrypt_content(preloaded_message)
                    {:ok, decrypted_message}

                  error ->
                    error
                end
              else
                {:error, :unauthorized}
              end
          end
      end
    else
      {:error, :rate_limited}
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
    # Check rate limiting first (with fallback if rate limiter not running)
    can_send =
      try do
        RateLimiter.can_send_message?(sender_id)
      rescue
        # Fallback to allowing if rate limiter not available
        _ -> true
      catch
        # Fallback if process not alive
        :exit, _ -> true
      end

    if can_send do
      # Get conversation to check type and for privacy validation
      conversation = Repo.get(Conversation, conversation_id)

      # For DM conversations, check privacy settings
      privacy_check =
        if conversation && conversation.type == "dm" do
          # Get the other user in the DM
          other_user_id =
            from(cm in ConversationMember,
              where:
                cm.conversation_id == ^conversation_id and cm.user_id != ^sender_id and
                  is_nil(cm.left_at),
              select: cm.user_id,
              limit: 1
            )
            |> Repo.one()

          if other_user_id do
            Elektrine.Privacy.can_send_dm?(sender_id, other_user_id)
          else
            {:ok, :allowed}
          end
        else
          {:ok, :allowed}
        end

      case privacy_check do
        {:error, reason} ->
          {:error, reason}

        {:ok, :allowed} ->
          case get_conversation_member(conversation_id, sender_id) do
            nil ->
              {:error, :unauthorized}

            member ->
              if ConversationMember.can_send_messages?(member) do
                result =
                  Message.media_changeset(
                    conversation_id,
                    sender_id,
                    media_urls,
                    content,
                    media_metadata,
                    conversation.type
                  )
                  |> Repo.insert()

                case result do
                  {:ok, message} ->
                    # Record for rate limiting (with fallback)
                    try do
                      RateLimiter.record_message(sender_id)
                    rescue
                      # Ignore if rate limiter not available
                      _ -> :ok
                    catch
                      # Ignore if process not alive
                      :exit, _ -> :ok
                    end

                    update_conversation_timestamp(conversation_id)

                    # Notify conversation members if content provided
                    if content do
                      notify_conversation_members(
                        conversation_id,
                        sender_id,
                        content,
                        message.id,
                        nil
                      )
                    end

                    broadcast_message(message)
                    preloaded_message = Repo.preload(message, [:sender, :reply_to, :reactions])
                    decrypted_message = Message.decrypt_content(preloaded_message)
                    {:ok, decrypted_message}

                  {:error, changeset} = error ->
                    require Logger
                    Logger.error("Failed to create media message: #{inspect(changeset.errors)}")
                    error

                  error ->
                    require Logger
                    Logger.error("Failed to create media message: #{inspect(error)}")
                    error
                end
              else
                {:error, :unauthorized}
              end
          end
      end
    else
      {:error, :rate_limited}
    end
  end

  @doc """
  Creates a voice message in a conversation.
  """
  def create_voice_message(conversation_id, sender_id, audio_url, duration, mime_type) do
    # Check rate limiting first (with fallback if rate limiter not running)
    can_send =
      try do
        RateLimiter.can_send_message?(sender_id)
      rescue
        _ -> true
      catch
        :exit, _ -> true
      end

    if can_send do
      # Verify sender is a member of the conversation
      case get_conversation_member(conversation_id, sender_id) do
        nil ->
          {:error, :unauthorized}

        member ->
          if ConversationMember.can_send_messages?(member) do
            result =
              %Message{}
              |> Message.changeset(%{
                conversation_id: conversation_id,
                sender_id: sender_id,
                content: nil,
                message_type: "voice",
                visibility: "conversation",
                post_type: "message",
                media_urls: [audio_url],
                media_metadata: %{
                  "duration" => duration,
                  "mime_type" => mime_type
                }
              })
              |> Repo.insert()

            case result do
              {:ok, message} ->
                # Record for rate limiting
                try do
                  RateLimiter.record_message(sender_id)
                rescue
                  _ -> :ok
                catch
                  :exit, _ -> :ok
                end

                # Update conversation's last_message_at
                update_conversation_timestamp(conversation_id)

                # Create notifications for other conversation members
                notify_conversation_members(
                  conversation_id,
                  sender_id,
                  "[Voice message]",
                  message.id,
                  nil
                )

                # Broadcast the message
                broadcast_message(message)

                # Preload and return
                preloaded_message = Repo.preload(message, [:sender, :reply_to, :reactions])
                {:ok, preloaded_message}

              error ->
                error
            end
          else
            {:error, :unauthorized}
          end
      end
    else
      {:error, :rate_limited}
    end
  end

  @doc """
  Creates a system message in a conversation (e.g., call logs, join/leave notifications).
  System messages are displayed differently but still need a sender_id (use first admin or creator).
  """
  def create_system_message(conversation_id, content, metadata \\ %{}) do
    # Get first admin user as sender for system messages
    sender_id =
      from(u in Elektrine.Accounts.User,
        where: u.is_admin == true,
        select: u.id,
        limit: 1
      )
      # Fallback to user ID 1
      |> Repo.one() || 1

    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      content: content,
      message_type: "system",
      visibility: "conversation",
      post_type: "message",
      media_metadata: metadata
    })
    |> Repo.insert()
    |> case do
      {:ok, message} = result ->
        # Update conversation's last message time
        from(c in Conversation, where: c.id == ^conversation_id)
        |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])

        # Broadcast to conversation
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{conversation_id}",
          {:new_message, message}
        )

        result

      error ->
        error
    end
  end

  @doc """
  Edits a message.
  """
  def edit_message(message_id, user_id, new_content) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        if Message.can_edit?(message, user_id) do
          message
          |> Message.edit_changeset(new_content)
          |> Repo.update()
          |> case do
            {:ok, updated_message} ->
              broadcast_message_edit(updated_message)

              # Side-effect (federation): skip in tests.
              Elektrine.Async.start(fn ->
                preloaded = Repo.preload(updated_message, :sender)
                Elektrine.ActivityPub.Outbox.federate_update(preloaded)
              end)

              preloaded_message = Repo.preload(updated_message, [:sender, :reply_to, :reactions])
              decrypted_message = Message.decrypt_content(preloaded_message)
              {:ok, decrypted_message}

            error ->
              error
          end
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Deletes a message.
  """
  def delete_message(message_id, user_id, is_admin \\ false) do
    case Repo.get(Message, message_id) |> Repo.preload(:conversation) do
      nil ->
        {:error, :not_found}

      message ->
        # Check if user is a moderator in the conversation
        member = get_conversation_member(message.conversation_id, user_id)
        is_mod = member && member.role in ["moderator", "admin", "owner"]

        if Message.can_delete?(message, user_id, is_admin) || is_mod do
          message
          |> Message.delete_changeset()
          |> Repo.update()
          |> case do
            {:ok, deleted_message} ->
              broadcast_message_delete(deleted_message)

              # Side-effect (federation): skip in tests.
              Elektrine.Async.start(fn ->
                preloaded = Repo.preload(deleted_message, :sender)
                Elektrine.ActivityPub.Outbox.federate_delete(preloaded)
              end)

              {:ok, deleted_message}

            error ->
              error
          end
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Admin deletes a message (bypasses ownership check).
  """
  def admin_delete_message(message_id, admin_user) do
    if admin_user.is_admin do
      case Repo.get(Message, message_id) do
        nil ->
          {:error, :not_found}

        message ->
          if message.deleted_at do
            {:error, :already_deleted}
          else
            message
            |> Message.delete_changeset()
            |> Repo.update()
            |> case do
              {:ok, deleted_message} ->
                broadcast_message_delete(deleted_message)
                {:ok, deleted_message}

              error ->
                error
            end
          end
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Get messages for a conversation with pagination support.
  Returns messages in reverse chronological order (newest first).
  """
  def get_conversation_messages(conversation_id, user_id, opts \\ []) do
    # Verify user is a member of the conversation before allowing access
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        # User is not a member - return empty result
        %{
          messages: [],
          has_more_older: false,
          has_more_newer: false,
          oldest_id: nil,
          newest_id: nil
        }

      _member ->
        # User is authorized, proceed with fetching messages
        fetch_conversation_messages(conversation_id, user_id, opts)
    end
  end

  defp fetch_conversation_messages(conversation_id, user_id, opts) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id, nil)
    after_id = Keyword.get(opts, :after_id, nil)

    base_query =
      from(m in Message,
        left_join: h in UserHiddenMessage,
        on: h.message_id == m.id and h.user_id == ^user_id,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at) and is_nil(h.id),
        limit: ^limit,
        preload: [
          sender: [:profile],
          reply_to: [sender: [:profile]],
          reactions: [user: []],
          link_preview: [],
          shared_message: [sender: [:profile], conversation: []]
        ]
      )

    query =
      cond do
        before_id ->
          # Load older messages (scrolling up)
          from(m in base_query,
            where: m.id < ^before_id,
            order_by: [desc: m.inserted_at]
          )

        after_id ->
          # Load newer messages (new messages since last load)
          from(m in base_query,
            where: m.id > ^after_id,
            order_by: [asc: m.inserted_at]
          )

        true ->
          # Initial load - get most recent messages
          from(m in base_query,
            order_by: [desc: m.inserted_at]
          )
      end

    messages = Repo.all(query)

    # If we loaded newer messages (after_id), reverse to maintain desc order
    messages = if after_id, do: Enum.reverse(messages), else: messages

    # Decrypt messages
    messages = Message.decrypt_messages(messages)

    # Check if there are more messages available
    has_more_older =
      if before_id || (!before_id && !after_id) do
        oldest_message = List.last(messages)

        if oldest_message do
          from(m in Message,
            where:
              m.conversation_id == ^conversation_id and
                m.id < ^oldest_message.id and
                is_nil(m.deleted_at),
            select: count(m.id)
          )
          |> Repo.one()
          |> Kernel.>(0)
        else
          false
        end
      else
        false
      end

    has_more_newer =
      if after_id do
        newest_message = List.first(messages)

        if newest_message do
          from(m in Message,
            where:
              m.conversation_id == ^conversation_id and
                m.id > ^newest_message.id and
                is_nil(m.deleted_at),
            select: count(m.id)
          )
          |> Repo.one()
          |> Kernel.>(0)
        else
          false
        end
      else
        false
      end

    oldest_id =
      case messages do
        [] -> nil
        _ -> List.last(messages).id
      end

    newest_id =
      case messages do
        [%{id: id} | _] -> id
        [] -> nil
      end

    %{
      messages: messages,
      has_more_older: has_more_older,
      has_more_newer: has_more_newer,
      oldest_id: oldest_id,
      newest_id: newest_id
    }
  end

  @doc """
  Gets messages for a conversation with pagination.
  """
  def get_messages(conversation_id, user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    # Default to showing only regular messages (not discussions) for backward compatibility
    post_types = Keyword.get(opts, :post_types, ["message", nil])

    # Verify user is a member of the conversation
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        query =
          from(m in Message,
            left_join: h in UserHiddenMessage,
            on: h.message_id == m.id and h.user_id == ^user_id,
            where:
              m.conversation_id == ^conversation_id and is_nil(m.deleted_at) and is_nil(h.id),
            order_by: [desc: m.inserted_at],
            limit: ^limit,
            preload: [
              sender: [:profile],
              reply_to: [sender: [:profile]],
              reactions: [user: []],
              link_preview: [],
              shared_message: [sender: [:profile], conversation: []]
            ]
          )

        # Apply post_type filter
        query =
          if nil in post_types do
            # If nil is in the list, we need to handle it specially
            non_nil_types = Enum.reject(post_types, &is_nil/1)
            from(m in query, where: m.post_type in ^non_nil_types or is_nil(m.post_type))
          else
            from(m in query, where: m.post_type in ^post_types)
          end

        query =
          if before_id do
            from(m in query, where: m.id < ^before_id)
          else
            query
          end

        messages = Repo.all(query)
        decrypted_messages = Message.decrypt_messages(messages)
        {:ok, Enum.reverse(decrypted_messages)}
    end
  end

  @doc """
  Searches messages within a specific conversation.
  """
  def search_messages_in_conversation(conversation_id, user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    # Verify user is a member of the conversation
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        # Extract keywords from query and hash them for blind index search
        keywords = Elektrine.Encryption.extract_keywords(query)

        if Enum.empty?(keywords) do
          # No valid keywords (all stop words or too short), return empty
          {:ok, []}
        else
          # Hash each keyword for this user
          keyword_hashes =
            Enum.map(keywords, fn kw ->
              Elektrine.Encryption.hash_keyword(kw, user_id)
            end)

          # Search for messages where ANY of the keyword hashes appear in search_index
          # Using PostgreSQL array overlap operator &&
          messages =
            from(m in Message,
              where:
                m.conversation_id == ^conversation_id and
                  is_nil(m.deleted_at) and
                  fragment("? && ?", m.search_index, ^keyword_hashes),
              order_by: [desc: m.inserted_at],
              limit: ^limit,
              preload: [sender: [:profile]]
            )
            |> Repo.all()
            |> Message.decrypt_messages()

          {:ok, messages}
        end
    end
  end

  @doc """
  Marks messages as read for a user in a conversation.
  """
  def mark_as_read(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      member ->
        member
        |> ConversationMember.mark_as_read_changeset()
        |> Repo.update()
    end
  end

  @doc """
  Updates the last read message for a user in a conversation.
  """
  def update_last_read_message(conversation_id, user_id, message_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      member ->
        member
        |> ConversationMember.update_last_read_message_changeset(message_id)
        |> Repo.update()
    end
  end

  @doc """
  Gets the last read message ID for a user in a conversation.
  """
  def get_last_read_message_id(conversation_id, user_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^conversation_id and
          cm.user_id == ^user_id and
          is_nil(cm.left_at),
      select: cm.last_read_message_id
    )
    |> Repo.one()
  end

  @doc """
  Clears message history for a specific user (marks messages as hidden for them).
  """
  def clear_history_for_user(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}

      _member ->
        # Get all messages in the conversation
        message_ids =
          from(m in Message,
            where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
            select: m.id
          )
          |> Repo.all()

        # Create hidden records for all messages
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        hidden_records =
          Enum.map(message_ids, fn message_id ->
            %{
              user_id: user_id,
              message_id: message_id,
              hidden_at: now,
              inserted_at: now,
              updated_at: now
            }
          end)

        case Repo.insert_all(UserHiddenMessage, hidden_records, on_conflict: :nothing) do
          {_count, _} -> {:ok, :cleared}
          _ -> {:error, :failed}
        end
    end
  end

  @doc """
  Gets users who have read a specific message.
  """
  def get_message_readers(message_id, conversation_id) do
    message = Repo.get!(Message, message_id)

    from(cm in ConversationMember,
      join: u in Elektrine.Accounts.User,
      on: u.id == cm.user_id,
      where:
        cm.conversation_id == ^conversation_id and
          is_nil(cm.left_at) and
          cm.user_id != ^message.sender_id and
          (not is_nil(cm.last_read_at) and cm.last_read_at >= ^message.inserted_at),
      select: %{
        user_id: u.id,
        username: u.username,
        avatar: u.avatar,
        read_at: cm.last_read_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets read status for messages in a conversation.
  """
  def get_read_status_for_messages(message_ids, conversation_id) do
    # Get all members and their last read times
    members_with_read_times =
      from(cm in ConversationMember,
        join: u in Elektrine.Accounts.User,
        on: u.id == cm.user_id,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: %{
          user_id: u.id,
          username: u.username,
          avatar: u.avatar,
          last_read_at: cm.last_read_at
        }
      )
      |> Repo.all()

    # Get messages with their timestamps
    messages =
      from(m in Message,
        where: m.id in ^message_ids,
        select: %{id: m.id, inserted_at: m.inserted_at, sender_id: m.sender_id}
      )
      |> Repo.all()

    # Build read status map
    Enum.reduce(messages, %{}, fn message, acc ->
      readers =
        Enum.filter(members_with_read_times, fn member ->
          member.user_id != message.sender_id and
            member.last_read_at != nil and
            NaiveDateTime.compare(member.last_read_at, message.inserted_at) != :lt
        end)

      Map.put(acc, message.id, readers)
    end)
  end

  @doc """
  Gets read status for last messages across multiple conversations.
  Takes a list of {conversation_id, message_id, message_inserted_at} tuples.
  Returns a map of conversation_id => reader_count.
  """
  def get_batch_last_message_read_status(message_info_list) do
    if Enum.empty?(message_info_list) do
      %{}
    else
      conversation_ids =
        Enum.map(message_info_list, fn {conv_id, _msg_id, _inserted_at} -> conv_id end)

      # Get all members with their last read times for all conversations at once
      members_by_conversation =
        from(cm in ConversationMember,
          where: cm.conversation_id in ^conversation_ids and is_nil(cm.left_at),
          select: %{
            conversation_id: cm.conversation_id,
            user_id: cm.user_id,
            last_read_at: cm.last_read_at
          }
        )
        |> Repo.all()
        |> Enum.group_by(& &1.conversation_id)

      # For each message, count how many members have read it
      message_info_list
      |> Enum.map(fn {conv_id, _msg_id, inserted_at} ->
        members = Map.get(members_by_conversation, conv_id, [])

        reader_count =
          Enum.count(members, fn member ->
            member.last_read_at != nil and
              NaiveDateTime.compare(member.last_read_at, inserted_at) != :lt
          end)

        # Subtract 1 to exclude the sender (who is also a member)
        reader_count = max(0, reader_count - 1)
        {conv_id, %{is_read: reader_count > 0, reader_count: reader_count}}
      end)
      |> Map.new()
    end
  end

  @doc """
  Gets unread message count for a specific conversation and user.
  """
  def get_conversation_unread_count(conversation_id, user_id) do
    # Get the user's last read timestamp for this conversation
    member =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id,
        select: cm.last_read_at
      )
      |> Repo.one()

    case member do
      nil ->
        0

      last_read_at when is_nil(last_read_at) ->
        # If never read, count all messages from others
        from(m in Message,
          where: m.conversation_id == ^conversation_id,
          where: m.sender_id != ^user_id,
          select: count(m.id)
        )
        |> Repo.one()

      last_read_at ->
        # Count messages after last read timestamp
        from(m in Message,
          where: m.conversation_id == ^conversation_id,
          where: m.sender_id != ^user_id,
          where: m.inserted_at > ^last_read_at,
          select: count(m.id)
        )
        |> Repo.one()
    end
  end

  @doc """
  Gets unread message counts for multiple conversations in a single query.
  Returns a map of conversation_id => unread_count.
  """
  def get_conversation_unread_counts(conversation_ids, user_id) when is_list(conversation_ids) do
    if Enum.empty?(conversation_ids) do
      %{}
    else
      # Count unread messages for all conversations in a single query
      # Joins with ConversationMember to get last_read_at per conversation
      # Counts messages that are:
      # - From other users (not the current user)
      # - Not deleted
      # - Either: user has never read (nil last_read_at) OR message is after last_read_at
      counts_query =
        from(m in Message,
          join: cm in ConversationMember,
          on: cm.conversation_id == m.conversation_id and cm.user_id == ^user_id,
          where: m.conversation_id in ^conversation_ids,
          where: m.sender_id != ^user_id,
          where: is_nil(m.deleted_at),
          where: is_nil(cm.last_read_at) or m.inserted_at > cm.last_read_at,
          group_by: m.conversation_id,
          select: {m.conversation_id, count(m.id)}
        )

      counts = Repo.all(counts_query) |> Map.new()

      # Return map with 0 for conversations with no unread messages
      conversation_ids
      |> Enum.map(fn conv_id ->
        count = Map.get(counts, conv_id, 0)
        {conv_id, count}
      end)
      |> Map.new()
    end
  end

  @doc """
  Gets unread message count for a user across all conversations.
  """
  def get_unread_count(user_id) do
    subquery =
      from(cm in ConversationMember,
        join: c in Conversation,
        on: c.id == cm.conversation_id,
        join: m in Message,
        on: m.conversation_id == c.id,
        where:
          cm.user_id == ^user_id and
            is_nil(cm.left_at) and
            (is_nil(cm.last_read_at) or m.inserted_at > cm.last_read_at) and
            m.sender_id != ^user_id and
            is_nil(m.deleted_at),
        select: count(m.id)
      )

    Repo.one(subquery) || 0
  end

  @doc """
  Pins a message in a community (moderators only).
  Only one message can be pinned at a time - unpins any existing pinned message.
  """
  def pin_message(message_id, user_id) do
    message = Repo.get!(Message, message_id)

    member = get_conversation_member(message.conversation_id, user_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]

    if is_mod do
      # First, unpin any existing pinned messages in this conversation
      previously_pinned =
        from(m in Message,
          where:
            m.conversation_id == ^message.conversation_id and m.is_pinned == true and
              m.id != ^message_id
        )
        |> Repo.all()

      Enum.each(previously_pinned, fn old_pinned ->
        old_pinned
        |> Ecto.Changeset.change(%{is_pinned: false, pinned_at: nil, pinned_by_id: nil})
        |> Repo.update()

        # Broadcast unpin for the old message
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{message.conversation_id}",
          {:message_unpinned, old_pinned}
        )
      end)

      # Now pin the new message
      case message
           |> Ecto.Changeset.change(%{
             is_pinned: true,
             pinned_at: DateTime.utc_now() |> DateTime.truncate(:second),
             pinned_by_id: user_id
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          # Broadcast pin update to all connected users
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:message_pinned, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Unpins a message in a community (moderators only).
  """
  def unpin_message(message_id, user_id) do
    message = Repo.get!(Message, message_id)

    member = get_conversation_member(message.conversation_id, user_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]

    if is_mod do
      case message
           |> Ecto.Changeset.change(%{
             is_pinned: false,
             pinned_at: nil,
             pinned_by_id: nil
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          # Broadcast unpin update to all connected users
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:message_unpinned, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists pinned messages for a conversation.
  """
  def list_pinned_messages(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and m.is_pinned == true,
      order_by: [desc: m.pinned_at],
      preload: [:sender, :pinned_by]
    )
    |> Repo.all()
    |> Message.decrypt_messages()
  end

  @doc """
  Generates a friendly URL path for a discussion post.
  """
  def discussion_post_path(community_name, post_id, title) do
    slug = Elektrine.Utils.Slug.discussion_url_slug(post_id, title)
    "/discussions/#{community_name}/p/#{slug}"
  end

  @doc """
  Gets a user's discussion posts across all communities.
  Returns most recent discussion posts by the user.
  """
  def get_user_discussion_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.sender_id == ^user_id and
          m.post_type == "discussion" and
          is_nil(m.deleted_at) and
          c.type == "community",
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [
        sender: [:profile],
        conversation: [],
        link_preview: [],
        flair: [],
        hashtags: []
      ]
    )
    |> Repo.all()
    |> Message.decrypt_messages()
  end

  ## Private Helpers

  defp get_conversation_member(conversation_id, user_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^conversation_id and
          cm.user_id == ^user_id and
          is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  defp update_conversation_timestamp(conversation_id) do
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])
  end

  defp broadcast_message(message) do
    # Ensure message has all associations loaded for the UI
    message_with_data =
      Repo.preload(message,
        sender: [:profile],
        reply_to: [sender: [:profile]],
        reactions: [user: []],
        link_preview: [],
        hashtags: []
      )

    # Check the conversation type to determine broadcast channel
    conversation = Repo.get!(Elektrine.Messaging.Conversation, message.conversation_id)

    # Only broadcast to conversation channel for chat messages (dm/group/channel)
    # Communities and timelines use their own channels
    is_chat_conversation = conversation.type in ["dm", "group", "channel"]

    if is_chat_conversation do
      # Broadcast to conversation participants for chat
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{message.conversation_id}",
        {:new_message, message_with_data}
      )

      # Broadcast to each participant's user topic for conversation list updates
      # Only fetch user_ids, not full ConversationMember structs
      member_user_ids =
        from(cm in ConversationMember,
          where:
            cm.conversation_id == ^message.conversation_id and
              is_nil(cm.left_at) and
              cm.user_id != ^message.sender_id,
          select: cm.user_id
        )
        |> Repo.all()

      Enum.each(member_user_ids, fn user_id ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}",
          {:new_message_notification, message_with_data}
        )
      end)
    end
  end

  defp broadcast_message_edit(message) do
    message_with_data =
      Repo.preload(message,
        sender: [:profile],
        reply_to: [sender: [:profile]],
        reactions: [user: []],
        link_preview: []
      )

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "conversation:#{message.conversation_id}",
      {:message_edited, message_with_data}
    )
  end

  defp broadcast_message_delete(message) do
    message_with_data =
      Repo.preload(message,
        sender: [:profile],
        reply_to: [sender: [:profile]],
        reactions: [user: []],
        link_preview: []
      )

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "conversation:#{message.conversation_id}",
      {:message_deleted, message_with_data}
    )
  end

  defp extract_and_attach_link_preview(message) do
    # Decrypt message to extract URLs from content
    decrypted = Message.decrypt_content(message)
    urls = LinkPreviewFetcher.extract_urls(decrypted.content)

    # Get the first URL (like Telegram, we'll preview the first link)
    case urls do
      [url | _] ->
        # Queue link preview via Oban worker for reliability
        result = FetchLinkPreviewWorker.enqueue(url, message.id)

        # Extract preview from result (if already exists)
        preview =
          case result do
            {:ok, {:exists, p}} -> p
            _ -> nil
          end

        if preview do
          # Update the message with the link preview ID
          {:ok, updated_message} =
            message
            |> Message.changeset(%{link_preview_id: preview.id})
            |> Repo.update()

          # Poll and broadcast when preview is ready
          # Worker handles the fetch and broadcasts via PubSub when ready
          # Background polling: skip in tests.
          Elektrine.Async.start(fn ->
            poll_and_broadcast_preview(updated_message, preview.id, 15)
          end)

          :ok
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp poll_and_broadcast_preview(_message, _preview_id, 0), do: :ok

  defp poll_and_broadcast_preview(message, preview_id, attempts_left) do
    # Wait 1 second
    :timer.sleep(1000)

    case Repo.get(LinkPreview, preview_id) do
      %{status: "success"} = preview ->
        # Preview is ready, broadcast the update
        updated_message =
          %{message | link_preview: preview}
          |> Repo.preload([:sender, :reply_to, :reactions, :hashtags], force: true)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{message.conversation_id}",
          {:message_link_preview_updated, updated_message}
        )

        :ok

      %{status: "pending"} ->
        # Still pending, try again
        poll_and_broadcast_preview(message, preview_id, attempts_left - 1)

      _ ->
        # Failed or not found
        :ok
    end
  end

  # Notifies conversation members about a new message
  defp notify_conversation_members(conversation_id, sender_id, content, message_id, reply_to_id) do
    # Get conversation details and sender in a single preload
    conversation = Repo.get!(Conversation, conversation_id)

    # Don't create notifications for community or timeline posts
    if conversation.type not in ["community", "timeline"] do
      notify_chat_members(conversation, sender_id, content, message_id, reply_to_id)
    end
  end

  defp notify_chat_members(conversation, sender_id, content, message_id, reply_to_id) do
    sender = Accounts.get_user!(sender_id)
    conversation_id = conversation.id

    # Get original message sender_id once if this is a reply
    original_sender_id =
      if reply_to_id do
        from(m in Message, where: m.id == ^reply_to_id, select: m.sender_id)
        |> Repo.one()
      end

    # If this is a reply, notify the original message author
    if original_sender_id && original_sender_id != sender_id do
      # Check if user wants to be notified about replies
      user = Elektrine.Accounts.get_user!(original_sender_id)

      if Map.get(user, :notify_on_reply, true) do
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

    # Get all members except the sender with user preferences in a single query
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

    # Create notifications in batch
    Enum.each(members_with_preferences, fn member ->
      # Skip notification if user already got a reply notification
      unless reply_to_id && member.user_id == original_sender_id do
        # Only send DM notifications if user has the preference enabled
        should_notify =
          case conversation.type do
            "dm" -> Map.get(member, :notify_on_direct_message, true)
            # Group/channel notifications always sent for now
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

    notify_mentions_in_chat(
      content,
      members_with_preferences,
      sender,
      sender_id,
      message_id
    )
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

  # ActivityPub Federation Support

  @doc """
  Creates a message from a federated source (ActivityPub).
  """
  def create_federated_message(attrs) do
    %Message{}
    |> Message.federated_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a message by its ActivityPub ID.
  """
  def get_message_by_activitypub_id(activitypub_id) do
    from(m in Message,
      where: m.activitypub_id == ^activitypub_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a message by an ActivityPub reference that may be either the canonical ID
  or the URL form used by some servers.
  """
  def get_message_by_activitypub_ref(activitypub_ref) when is_binary(activitypub_ref) do
    refs = activitypub_ref_variants(activitypub_ref)

    if Enum.empty?(refs) do
      nil
    else
      from(m in Message,
        where: m.activitypub_id in ^refs or m.activitypub_url in ^refs,
        limit: 1,
        preload: [:sender, :remote_actor]
      )
      |> Repo.one()
    end
  end

  def get_message_by_activitypub_ref(_), do: nil

  @doc """
  Gets multiple messages by their ActivityPub IDs.
  """
  def get_messages_by_activitypub_ids(activitypub_ids) when is_list(activitypub_ids) do
    from(m in Message,
      where: m.activitypub_id in ^activitypub_ids
    )
    |> Repo.all()
  end

  defp activitypub_ref_variants(ref) do
    trimmed = String.trim(ref)
    without_fragment = trimmed |> String.split("#", parts: 2) |> hd()
    without_trailing_slash = String.trim_trailing(without_fragment, "/")

    [trimmed, without_fragment, without_trailing_slash]
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.uniq()
  end

  @doc """
  Gets local replies to messages with the given ActivityPub IDs.
  Returns local messages (where sender_id is not nil) that reply to messages
  with matching activitypub_ids.
  """
  def get_local_replies_to_activitypub_ids(activitypub_ids) when is_list(activitypub_ids) do
    # First get the local message IDs for these ActivityPub IDs
    parent_messages =
      from(m in Message,
        where: m.activitypub_id in ^activitypub_ids,
        select: %{id: m.id, activitypub_id: m.activitypub_id}
      )
      |> Repo.all()

    parent_ids = Enum.map(parent_messages, & &1.id)
    parent_id_to_apid = Map.new(parent_messages, fn m -> {m.id, m.activitypub_id} end)

    if Enum.empty?(parent_ids) do
      []
    else
      # Get local replies (sender_id not nil means it's from a local user)
      from(m in Message,
        where: m.reply_to_id in ^parent_ids and not is_nil(m.sender_id),
        preload: [:sender]
      )
      |> Repo.all()
      |> Enum.map(fn msg ->
        # Attach parent ActivityPub ID for threading
        Map.put(msg, :parent_activitypub_id, Map.get(parent_id_to_apid, msg.reply_to_id))
      end)
    end
  end

  @doc """
  Gets cached replies (local and federated) to messages with the given ActivityPub IDs.
  Returns messages that reply to matched parents and annotates each with `:parent_activitypub_id`
  for thread reconstruction in ActivityPub-like views.
  """
  def get_cached_replies_to_activitypub_ids(activitypub_ids) when is_list(activitypub_ids) do
    sanitized_ids =
      activitypub_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if Enum.empty?(sanitized_ids) do
      []
    else
      parent_messages =
        from(m in Message,
          where: m.activitypub_id in ^sanitized_ids,
          select: %{id: m.id, activitypub_id: m.activitypub_id}
        )
        |> Repo.all()

      parent_ids = Enum.map(parent_messages, & &1.id)
      parent_id_to_apid = Map.new(parent_messages, fn m -> {m.id, m.activitypub_id} end)

      if Enum.empty?(parent_ids) do
        []
      else
        from(m in Message,
          where:
            m.reply_to_id in ^parent_ids and
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status)),
          order_by: [asc: m.inserted_at],
          preload: [:sender, :remote_actor]
        )
        |> Repo.all()
        |> Enum.map(fn msg ->
          Map.put(msg, :parent_activitypub_id, Map.get(parent_id_to_apid, msg.reply_to_id))
        end)
      end
    end
  end

  @doc """
  Gets a message by ID.
  """
  def get_message(id) do
    Repo.get(Message, id)
  end

  @doc """
  Updates a message.
  """
  def update_message(message, attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates message metadata fields only (like media_metadata, engagement counts).
  Safe for both regular and federated messages since it doesn't require conversation_id/sender_id.
  """
  def update_message_metadata(message, attrs) do
    message
    |> Message.metadata_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Creates a like from a federated source.
  """
  def create_federated_like(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedLike

    # Check if already liked
    existing =
      Repo.get_by(FederatedLike, message_id: message_id, remote_actor_id: remote_actor_id)

    if existing do
      {:ok, :already_liked}
    else
      # Create like record
      case %FederatedLike{}
           |> FederatedLike.changeset(%{message_id: message_id, remote_actor_id: remote_actor_id})
           |> Repo.insert() do
        {:ok, _like} ->
          # Increment like count
          from(m in Message,
            where: m.id == ^message_id,
            update: [inc: [like_count: 1]]
          )
          |> Repo.update_all([])

          {:ok, :liked}

        {:error, %Ecto.Changeset{errors: [message_id: _]}} ->
          # Race condition - already liked
          {:ok, :already_liked}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes a like from a federated source.
  """
  def delete_federated_like(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedLike

    # Delete like record
    case Repo.get_by(FederatedLike, message_id: message_id, remote_actor_id: remote_actor_id) do
      nil ->
        {:ok, :not_liked}

      like ->
        Repo.delete(like)

        # Decrement like count
        from(m in Message,
          where: m.id == ^message_id and m.like_count > 0,
          update: [inc: [like_count: -1]]
        )
        |> Repo.update_all([])

        {:ok, :unliked}
    end
  end

  @doc """
  Creates a dislike (downvote) from a federated source.
  Used by Lemmy and other platforms that support downvotes.
  """
  def create_federated_dislike(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedDislike

    # Check if already disliked
    existing =
      Repo.get_by(FederatedDislike, message_id: message_id, remote_actor_id: remote_actor_id)

    if existing do
      {:ok, :already_disliked}
    else
      # Create dislike record
      case %FederatedDislike{}
           |> FederatedDislike.changeset(%{
             message_id: message_id,
             remote_actor_id: remote_actor_id
           })
           |> Repo.insert() do
        {:ok, _dislike} ->
          # Increment dislike count
          from(m in Message,
            where: m.id == ^message_id,
            update: [inc: [dislike_count: 1]]
          )
          |> Repo.update_all([])

          {:ok, :disliked}

        {:error, %Ecto.Changeset{errors: [message_id: _]}} ->
          # Race condition - already disliked
          {:ok, :already_disliked}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes a dislike from a federated source.
  """
  def delete_federated_dislike(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedDislike

    # Delete dislike record
    case Repo.get_by(FederatedDislike, message_id: message_id, remote_actor_id: remote_actor_id) do
      nil ->
        {:ok, :not_disliked}

      dislike ->
        Repo.delete(dislike)

        # Decrement dislike count
        from(m in Message,
          where: m.id == ^message_id and m.dislike_count > 0,
          update: [inc: [dislike_count: -1]]
        )
        |> Repo.update_all([])

        {:ok, :undisliked}
    end
  end

  @doc """
  Creates a boost (announce) record from a federated source.
  Tracks which remote actors have boosted a local post.
  """
  def create_federated_boost(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedBoost

    # Check if already boosted
    existing =
      Repo.get_by(FederatedBoost, message_id: message_id, remote_actor_id: remote_actor_id)

    if existing do
      {:ok, :already_boosted}
    else
      # Create boost record
      case %FederatedBoost{}
           |> FederatedBoost.changeset(%{
             message_id: message_id,
             remote_actor_id: remote_actor_id
           })
           |> Repo.insert() do
        {:ok, _boost} ->
          # Increment share count
          from(m in Message,
            where: m.id == ^message_id,
            update: [inc: [share_count: 1]]
          )
          |> Repo.update_all([])

          {:ok, :boosted}

        {:error, %Ecto.Changeset{errors: [message_id: _]}} ->
          # Race condition - already boosted
          {:ok, :already_boosted}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes a boost from a federated source.
  """
  def delete_federated_boost(message_id, remote_actor_id) do
    alias Elektrine.Messaging.FederatedBoost

    # Delete boost record
    case Repo.get_by(FederatedBoost, message_id: message_id, remote_actor_id: remote_actor_id) do
      nil ->
        {:ok, :not_boosted}

      boost ->
        Repo.delete(boost)

        # Decrement share count
        from(m in Message,
          where: m.id == ^message_id and m.share_count > 0,
          update: [inc: [share_count: -1]]
        )
        |> Repo.update_all([])

        {:ok, :unboosted}
    end
  end

  @doc """
  Creates an emoji reaction from a remote actor (EmojiReact activity).
  Supports custom emoji with URLs (4th argument).
  """
  def create_federated_emoji_reaction(message_id, remote_actor_id, emoji, emoji_url \\ nil) do
    alias Elektrine.Messaging.MessageReaction

    # Check if already reacted with this emoji
    existing =
      Repo.get_by(MessageReaction,
        message_id: message_id,
        remote_actor_id: remote_actor_id,
        emoji: emoji
      )

    if existing do
      {:ok, :already_reacted}
    else
      insert_result =
        try do
          %MessageReaction{}
          |> MessageReaction.changeset(%{
            message_id: message_id,
            remote_actor_id: remote_actor_id,
            emoji: emoji,
            emoji_url: emoji_url,
            federated: true
          })
          |> Repo.insert()
        rescue
          err in [Postgrex.Error] ->
            case err do
              %Postgrex.Error{postgres: %{code: :not_null_violation}} ->
                Logger.error(
                  "Cannot store federated emoji reaction because message_reactions.user_id is NOT NULL. " <>
                    "Run migrations (especially make_message_reactions_user_id_nullable) so remote reactions can persist. " <>
                    "Details: #{Exception.message(err)}"
                )

                {:error, :user_id_not_nullable}

              _ ->
                reraise(err, __STACKTRACE__)
            end
        end

      # Create reaction record
      case insert_result do
        {:ok, reaction} ->
          {:ok, reaction}

        {:error, %Ecto.Changeset{errors: [message_id: _]}} ->
          # Race condition - already reacted
          {:ok, :already_reacted}

        {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}} = err} ->
          Logger.error(
            "Cannot store federated emoji reaction because message_reactions.user_id is NOT NULL. " <>
              "Run migrations (especially make_message_reactions_user_id_nullable) so remote reactions can persist. " <>
              "Details: #{Exception.message(err)}"
          )

          {:error, :user_id_not_nullable}

        {:error, :user_id_not_nullable} ->
          {:error, :user_id_not_nullable}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes an emoji reaction from a remote actor (Undo EmojiReact).
  """
  def delete_federated_emoji_reaction(message_id, remote_actor_id, emoji) do
    alias Elektrine.Messaging.MessageReaction

    # Delete reaction record
    case Repo.get_by(MessageReaction,
           message_id: message_id,
           remote_actor_id: remote_actor_id,
           emoji: emoji
         ) do
      nil ->
        {:ok, :not_reacted}

      reaction ->
        Repo.delete(reaction)
        {:ok, :unreacted}
    end
  end

  @doc """
  Increments the share count for a message.
  """
  def increment_share_count(message_id) do
    from(m in Message,
      where: m.id == ^message_id,
      update: [inc: [share_count: 1]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Decrements the share count for a message.
  """
  def decrement_share_count(message_id) do
    from(m in Message,
      where: m.id == ^message_id and m.share_count > 0,
      update: [inc: [share_count: -1]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Increments the quote count for a message.
  """
  def increment_quote_count(message_id) do
    from(m in Message,
      where: m.id == ^message_id,
      update: [inc: [quote_count: 1]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Decrements the quote count for a message.
  """
  def decrement_quote_count(message_id) do
    from(m in Message,
      where: m.id == ^message_id and m.quote_count > 0,
      update: [inc: [quote_count: -1]]
    )
    |> Repo.update_all([])
  end

  ## Post Loading Helpers

  @doc """
  Gets a discussion post by ID with standard preloads for display.
  """
  def get_discussion_post(message_id) do
    Repo.get(Message, message_id)
    |> Repo.preload(discussion_post_preloads())
    |> Message.decrypt_content()
  end

  @doc """
  Gets a discussion post by ID with standard preloads, using force reload.
  """
  def get_discussion_post!(message_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    message = Repo.get!(Message, message_id)

    if force do
      Repo.preload(message, discussion_post_preloads(), force: true)
    else
      Repo.preload(message, discussion_post_preloads())
    end
    |> Message.decrypt_content()
  end

  @doc """
  Gets a timeline post by ID with standard preloads for display.
  """
  def get_timeline_post(message_id) do
    Repo.get(Message, message_id)
    |> Repo.preload(timeline_post_preloads())
    |> Message.decrypt_content()
  end

  @doc """
  Gets a timeline post by ID with standard preloads, using force reload.
  """
  def get_timeline_post!(message_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    message = Repo.get!(Message, message_id)

    if force do
      Repo.preload(message, timeline_post_preloads(), force: true)
    else
      Repo.preload(message, timeline_post_preloads())
    end
    |> Message.decrypt_content()
  end

  @doc """
  Standard preloads for discussion posts.
  """
  def discussion_post_preloads do
    [
      sender: [:profile],
      remote_actor: [],
      conversation: [],
      link_preview: [],
      hashtags: [],
      flair: [],
      reply_to: [sender: [:profile], remote_actor: []],
      quoted_message: [sender: [:profile], remote_actor: [], link_preview: []],
      shared_message: [
        sender: [:profile],
        conversation: [],
        remote_actor: [],
        link_preview: [],
        poll: [options: []],
        quoted_message: [sender: [:profile], remote_actor: [], link_preview: []]
      ],
      poll: [options: []]
    ]
  end

  @doc """
  Standard preloads for timeline posts.
  """
  def timeline_post_preloads do
    [
      sender: [:profile],
      conversation: [],
      remote_actor: [],
      link_preview: [],
      hashtags: [],
      reply_to: [sender: [:profile], remote_actor: []],
      quoted_message: [sender: [:profile], remote_actor: [], link_preview: []],
      shared_message: [
        sender: [:profile],
        conversation: [],
        remote_actor: [],
        link_preview: [],
        poll: [options: []],
        quoted_message: [sender: [:profile], remote_actor: [], link_preview: []]
      ],
      poll: [options: []]
    ]
  end

  @doc """
  Lightweight preloads for high-traffic timeline feed queries.
  """
  def timeline_feed_preloads do
    [
      sender: [:profile],
      remote_actor: [],
      link_preview: [],
      reply_to: [sender: [:profile], remote_actor: []],
      quoted_message: [sender: [:profile], remote_actor: [], link_preview: []],
      shared_message: [
        sender: [:profile],
        remote_actor: [],
        link_preview: [],
        poll: [options: []],
        quoted_message: [sender: [:profile], remote_actor: [], link_preview: []]
      ],
      poll: [options: []]
    ]
  end

  @doc """
  Standard preloads for timeline replies.
  """
  def timeline_reply_preloads do
    [
      sender: [:profile],
      remote_actor: [],
      link_preview: [],
      hashtags: [],
      quoted_message: [sender: [:profile], remote_actor: [], link_preview: []],
      shared_message: [
        sender: [:profile],
        conversation: [],
        remote_actor: [],
        link_preview: [],
        poll: [options: []],
        quoted_message: [sender: [:profile], remote_actor: [], link_preview: []]
      ],
      poll: [options: []]
    ]
  end

  @doc """
  Lightweight preloads for inline timeline reply previews.
  """
  def timeline_reply_preview_preloads do
    [
      sender: [:profile],
      remote_actor: [],
      link_preview: [],
      quoted_message: [sender: [:profile], remote_actor: []]
    ]
  end

  @doc """
  Syncs engagement counts for a remote post from the source instance.

  Takes an ActivityPub post object (map) and syncs Lemmy counts if it's a Lemmy post.

  Note: We only fetch Lemmy counts because:
  - Mastodon/Pleroma don't expose like counts via their API to remote fetchers
  - Their ActivityPub objects don't include likes collections for privacy reasons
  - Lemmy exposes a public API with full vote counts

  Returns `:ok` on success or if no update needed.
  """
  def sync_remote_counts(post_object) when is_map(post_object) do
    post_id = post_object["id"]

    # Only sync Lemmy posts - other instances don't expose counts
    lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id)

    if lemmy_counts do
      case Repo.get_by(Message, activitypub_id: post_id) do
        nil ->
          :ok

        message ->
          like_count = lemmy_counts.score
          reply_count = lemmy_counts.comments

          # Update if counts have changed
          updates = %{}

          updates =
            if like_count != (message.like_count || 0),
              do: Map.put(updates, :like_count, like_count),
              else: updates

          updates =
            if reply_count != (message.reply_count || 0),
              do: Map.put(updates, :reply_count, reply_count),
              else: updates

          if map_size(updates) > 0 do
            message
            |> Ecto.Changeset.change(updates)
            |> Repo.update()

            # Broadcast the update so all clients showing this post get updated
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "timeline:public",
              {:post_counts_updated,
               %{
                 message_id: message.id,
                 counts: %{
                   like_count: Map.get(updates, :like_count, message.like_count || 0),
                   share_count: message.share_count || 0,
                   reply_count: Map.get(updates, :reply_count, message.reply_count || 0)
                 }
               }}
            )
          end

          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def sync_remote_counts(_), do: :ok
end
