defmodule ElektrineChatWeb.API.ConversationController do
  @moduledoc """
  API controller for chat conversations.
  """
  use ElektrineChatWeb, :controller

  alias ElektrineChat, as: Messaging

  action_fallback ElektrineChatWeb.FallbackController

  @doc """
  GET /api/conversations
  Lists all conversations for the current user.
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 50)

    conversations = Messaging.list_conversations(user.id, limit: limit)

    conn
    |> put_status(:ok)
    |> json(%{
      conversations: Enum.map(conversations, &format_conversation(&1, user.id))
    })
  end

  @doc """
  GET /api/conversations/:id
  Gets a specific conversation with recent messages.
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messaging.get_conversation!(String.to_integer(id), user.id) do
      {:ok, conversation} ->
        {conv_data, messages} = format_conversation_with_messages(conversation, user.id)

        conn
        |> put_status(:ok)
        |> json(%{conversation: conv_data, messages: messages})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      {:error, :not_member} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You are not a member of this conversation"})
    end
  end

  @doc """
  POST /api/conversations
  Creates a new conversation (DM, group, or channel).

  Params:
    - type: "dm" | "group" | "channel" (required)
    - user_id: Target user ID (required for DM)
    - name: Conversation name (required for group/channel)
    - description: Optional description
    - member_ids: List of user IDs to add (for group)
    - is_public: Whether group/channel is public (default false)
  """
  def create(conn, %{"type" => "dm", "user_id" => target_user_id}) do
    user = conn.assigns[:current_user]

    case Messaging.create_dm_conversation(user.id, String.to_integer(target_user_id)) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Conversation created",
          conversation: format_conversation(conversation, user.id)
        })

      {:error, :self_dm} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Cannot create conversation with yourself"})

      {:error, :user_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      {:error, :privacy_blocked} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Cannot message this user due to privacy settings"})

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many conversations created. Please try again later."})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create conversation: #{inspect(reason)}"})
    end
  end

  def create(conn, %{"type" => "group"} = params) do
    user = conn.assigns[:current_user]

    attrs = %{
      name: params["name"],
      description: params["description"],
      avatar_url: params["avatar_url"],
      is_public: params["is_public"] == true
    }

    member_ids = params["member_ids"] || []

    case Messaging.create_group_conversation(user.id, attrs, member_ids) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Group created",
          conversation: format_conversation(conversation, user.id)
        })

      {:error, :limit_reached} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Maximum group limit reached"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Validation failed", errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create group: #{inspect(reason)}"})
    end
  end

  def create(conn, %{"type" => "channel"} = params) do
    user = conn.assigns[:current_user]

    attrs = %{
      name: params["name"],
      description: params["description"],
      avatar_url: params["avatar_url"],
      # Channels are public by default
      is_public: params["is_public"] != false
    }

    case Messaging.create_channel(user.id, attrs) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Channel created",
          conversation: format_conversation(conversation, user.id)
        })

      {:error, :limit_reached} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Maximum channel limit reached"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Validation failed", errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create channel: #{inspect(reason)}"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: type (dm, group, or channel)"})
  end

  @doc """
  PUT /api/conversations/:id
  Updates a conversation (name, description, etc.).
  """
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    # Check if user has permission to update
    case Messaging.get_conversation_member(conversation_id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      member when member.role not in ["owner", "admin"] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Only owners and admins can update conversations"})

      _member ->
        # Get the conversation and update it
        case Messaging.get_conversation!(conversation_id, user.id) do
          {:ok, conversation} ->
            attrs =
              %{}
              |> maybe_put(:name, params["name"])
              |> maybe_put(:description, params["description"])
              |> maybe_put(:avatar_url, params["avatar_url"])

            case Messaging.update_conversation(conversation, attrs) do
              {:ok, updated} ->
                conn
                |> put_status(:ok)
                |> json(%{
                  message: "Conversation updated",
                  conversation: format_conversation(updated, user.id)
                })

              {:error, %Ecto.Changeset{} = changeset} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Validation failed", errors: format_errors(changeset)})
            end

          {:error, _} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Conversation not found"})
        end
    end
  end

  @doc """
  DELETE /api/conversations/:id
  Deletes a conversation (owner only) or leaves it.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    case Messaging.get_conversation_member(conversation_id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      member ->
        if member.role == "owner" do
          # Owner deletes the entire conversation
          case Messaging.delete_conversation(conversation_id) do
            {:ok, _} ->
              conn
              |> put_status(:ok)
              |> json(%{message: "Conversation deleted"})

            {:error, reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to delete: #{inspect(reason)}"})
          end
        else
          # Non-owner leaves the conversation
          case Messaging.remove_member_from_conversation(conversation_id, user.id) do
            {:ok, _} ->
              conn
              |> put_status(:ok)
              |> json(%{message: "Left conversation"})

            {:error, reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to leave: #{inspect(reason)}"})
          end
        end
    end
  end

  @doc """
  POST /api/conversations/:id/join
  Joins a public conversation.
  """
  def join(conn, %{"conversation_id" => id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    case Messaging.join_conversation(conversation_id, user.id) do
      {:ok, _member} ->
        {:ok, conversation} = Messaging.get_conversation!(conversation_id, user.id)

        conn
        |> put_status(:ok)
        |> json(%{
          message: "Joined conversation",
          conversation: format_conversation(conversation, user.id)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      {:error, :not_public} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This conversation is not public"})

      {:error, :not_public_channel} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This conversation is not public"})

      {:error, :must_join_server} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Join the server first before joining this channel"})

      {:error, :already_member} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Already a member of this conversation"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to join: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/conversations/:id/leave
  Leaves a conversation.
  """
  def leave(conn, %{"conversation_id" => id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    case Messaging.remove_member_from_conversation(conversation_id, user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Left conversation"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found or not a member"})

      {:error, :owner_cannot_leave} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Owners must transfer ownership or delete the conversation"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to leave: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/conversations/:id/read
  Marks conversation as read.
  """
  def mark_read(conn, %{"conversation_id" => id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    case Messaging.mark_as_read(conversation_id, user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Marked as read"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to mark as read: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/conversations/:id/members
  Lists members of a conversation.
  """
  def members(conn, %{"conversation_id" => id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    # Verify user is a member
    case Messaging.get_conversation_member(conversation_id, user.id) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not a member of this conversation"})

      _member ->
        members = Messaging.get_conversation_members(conversation_id)

        conn
        |> put_status(:ok)
        |> json(%{members: Enum.map(members, &format_member/1)})
    end
  end

  @doc """
  POST /api/conversations/:id/members
  Adds a member to a conversation.
  """
  def add_member(conn, %{"conversation_id" => id, "user_id" => target_user_id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)

    # Check if user has permission to add members
    case Messaging.get_conversation_member(conversation_id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      member when member.role not in ["owner", "admin", "moderator"] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to add members"})

      _member ->
        role = "member"

        case Messaging.add_member_to_conversation(
               conversation_id,
               String.to_integer(target_user_id),
               role,
               user.id
             ) do
          {:ok, new_member} ->
            conn
            |> put_status(:created)
            |> json(%{
              message: "Member added",
              member: format_member(new_member)
            })

          {:error, :user_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "User not found"})

          {:error, :already_member} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "User is already a member"})

          {:error, :privacy_blocked} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Cannot add user due to privacy settings"})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to add member: #{inspect(reason)}"})
        end
    end
  end

  def add_member(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: user_id"})
  end

  @doc """
  DELETE /api/conversations/:id/members/:user_id
  Removes a member from a conversation.
  """
  def remove_member(conn, %{"conversation_id" => id, "user_id" => target_user_id}) do
    user = conn.assigns[:current_user]
    conversation_id = String.to_integer(id)
    target_id = String.to_integer(target_user_id)

    # Check if user has permission to remove members
    case Messaging.get_conversation_member(conversation_id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      member when member.role not in ["owner", "admin", "moderator"] and user.id != target_id ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to remove members"})

      _member ->
        case Messaging.remove_member_from_conversation(conversation_id, target_id) do
          {:ok, _} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Member removed"})

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Member not found"})

          {:error, :owner_cannot_leave} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Cannot remove the owner"})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to remove member: #{inspect(reason)}"})
        end
    end
  end

  # Private helpers

  defp format_conversation(conversation, current_user_id) do
    # Get unread count if not already loaded
    unread_count =
      case Map.get(conversation, :unread_count) do
        nil -> Messaging.get_conversation_unread_count(conversation.id, current_user_id)
        count -> count
      end

    %{
      id: conversation.id,
      name: conversation.name,
      description: conversation.description,
      type: conversation.type,
      server_id: Map.get(conversation, :server_id),
      avatar_url: conversation.avatar_url,
      is_public: conversation.is_public,
      member_count: conversation.member_count,
      hash: conversation.hash,
      channel_topic: Map.get(conversation, :channel_topic),
      channel_position: Map.get(conversation, :channel_position, 0),
      creator_id: conversation.creator_id,
      last_message_at: conversation.last_message_at,
      unread_count: unread_count,
      last_message: format_last_message(conversation),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  defp format_conversation_with_messages(conversation, current_user_id) do
    base = format_conversation(conversation, current_user_id)

    members =
      case Map.get(conversation, :members) do
        nil -> []
        members -> Enum.map(members, &format_member/1)
      end

    # Fetch messages from messages table
    messages =
      case Messaging.get_messages(conversation.id, current_user_id, limit: 50) do
        {:ok, msgs} -> Enum.map(msgs, &format_message/1)
        {:error, _} -> []
      end

    conv_data = Map.put(base, :members, members)
    {conv_data, messages}
  end

  defp format_last_message(%{last_message: nil}), do: nil
  defp format_last_message(%{last_message: %Ecto.Association.NotLoaded{}}), do: nil
  defp format_last_message(%{last_message: message}), do: format_message(message)
  defp format_last_message(_), do: nil

  defp format_message(message) do
    %{
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      media_urls: message.media_urls,
      sender_id: message.sender_id,
      sender: format_user(message.sender),
      reply_to_id: message.reply_to_id,
      like_count: message.like_count || 0,
      reply_count: message.reply_count || 0,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      created_at: message.inserted_at
    }
  end

  @doc """
  POST /api/conversations/:conversation_id/upload
  Uploads a media file for a conversation.
  """
  def upload_media(conn, %{"conversation_id" => conversation_id, "file" => upload}) do
    user = conn.assigns[:current_user]
    conv_id = String.to_integer(conversation_id)

    # Verify user is a member
    case Messaging.get_conversation_member(conv_id, user.id) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not a member of this conversation"})

      _member ->
        case Elektrine.Uploads.upload_chat_attachment(upload, user.id) do
          {:ok, metadata} ->
            # Build the full URL
            url = Elektrine.Uploads.media_url(metadata.key)

            conn
            |> put_status(:created)
            |> json(%{
              url: url,
              key: metadata.key,
              filename: metadata.filename,
              content_type: metadata.content_type,
              size: metadata.size
            })

          {:error, {:file_too_large, msg}} ->
            conn
            |> put_status(:request_entity_too_large)
            |> json(%{error: msg})

          {:error, {:invalid_file_type, msg}} ->
            conn
            |> put_status(:unsupported_media_type)
            |> json(%{error: msg})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Upload failed: #{inspect(reason)}"})
        end
    end
  end

  def upload_media(conn, %{"conversation_id" => _conversation_id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing file parameter"})
  end

  defp format_member(member) do
    %{
      id: member.id,
      user_id: member.user_id,
      role: member.role,
      joined_at: member.joined_at,
      last_read_at: member.last_read_at,
      user: format_user(member.user)
    }
  end

  defp format_user(nil), do: nil
  defp format_user(%Ecto.Association.NotLoaded{}), do: nil

  defp format_user(user) do
    %{
      id: user.id,
      username: user.username,
      avatar: user.avatar
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
end
