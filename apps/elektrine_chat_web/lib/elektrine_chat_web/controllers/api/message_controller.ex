defmodule ElektrineChatWeb.API.MessageController do
  @moduledoc """
  API controller for chat messages.

  Uses the new ChatMessages module for DM/group/channel messages,
  separate from timeline posts which remain in the Messages module.
  """
  use ElektrineChatWeb, :controller

  alias ElektrineChat, as: Messaging

  action_fallback ElektrineChatWeb.FallbackController

  @doc """
  GET /api/conversations/:conversation_id/messages
  Lists messages for a conversation with pagination.

  Query params:
    - before_id: Get messages before this ID (for loading older)
    - after_id: Get messages after this ID (for loading newer)
    - limit: Number of messages to return (default 50, max 100)
  """
  def index(conn, %{"conversation_id" => conversation_id} = params) do
    user = conn.assigns[:current_user]
    conv_id = String.to_integer(conversation_id)

    # Verify user is a member
    case Messaging.get_conversation_member(conv_id, user.id) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not a member of this conversation"})

      _member ->
        opts =
          [
            limit: min(parse_int(params["limit"], 50), 100),
            before_id: parse_int(params["before_id"], nil)
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        case Messaging.get_messages(conv_id, user.id, opts) do
          {:ok, messages} ->
            conn
            |> put_status(:ok)
            |> json(%{
              messages: Enum.map(messages, &format_message/1),
              has_more: length(messages) >= Keyword.get(opts, :limit, 50)
            })

          {:error, _reason} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Unable to load messages"})
        end
    end
  end

  @doc """
  POST /api/conversations/:conversation_id/messages
  Sends a new message in a conversation.

  Params:
    - content: Message text (required)
    - reply_to_id: ID of message being replied to (optional)
    - message_type: "text" | "image" | "file" (default: "text")
    - media_urls: Array of media URLs (for image/file messages)
  """
  def create(conn, %{"conversation_id" => conversation_id} = params) do
    user = conn.assigns[:current_user]
    conv_id = String.to_integer(conversation_id)

    # Verify user is a member
    case Messaging.get_conversation_member(conv_id, user.id) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not a member of this conversation"})

      member when member.role == "readonly" ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to send messages"})

      _member ->
        content = params["content"] || ""
        reply_to_id = parse_int(params["reply_to_id"], nil)
        message_type = params["message_type"] || "text"

        result =
          case message_type do
            "text" ->
              opts = if reply_to_id, do: [reply_to_id: reply_to_id], else: []
              Messaging.create_chat_text_message(conv_id, user.id, content, opts)

            "image" ->
              media_urls = params["media_urls"] || []
              media_metadata = params["media_metadata"] || %{}

              Messaging.create_chat_media_message(
                conv_id,
                user.id,
                media_urls,
                content,
                media_metadata
              )

            "file" ->
              media_urls = params["media_urls"] || []
              media_metadata = params["media_metadata"] || %{}

              Messaging.create_chat_media_message(
                conv_id,
                user.id,
                media_urls,
                content,
                media_metadata
              )

            "voice" ->
              audio_url = List.first(params["media_urls"] || [])
              duration = params["duration"] || 0
              mime_type = params["mime_type"] || "audio/webm"

              Messaging.create_chat_voice_message(
                conv_id,
                user.id,
                audio_url,
                duration,
                mime_type
              )

            _ ->
              {:error, :invalid_message_type}
          end

        case result do
          {:ok, message} ->
            conn
            |> put_status(:created)
            |> json(%{
              message: format_message(message)
            })

          {:error, :empty_message} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Message content cannot be empty"})

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "You're sending messages too quickly. Please slow down."})

          {:error, :timed_out} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "You are currently timed out from this conversation"})

          {:error, :invalid_message_type} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid message type. Use: text, image, file, or voice"})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Validation failed", errors: format_errors(changeset)})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to send message: #{inspect(reason)}"})
        end
    end
  end

  @doc """
  PUT /api/messages/:id
  Edits a message.

  Params:
    - content: New message content (required)
  """
  def update(conn, %{"id" => id, "content" => new_content}) do
    user = conn.assigns[:current_user]
    message_id = String.to_integer(id)

    case Messaging.edit_chat_message(message_id, user.id, new_content) do
      {:ok, message} ->
        conn
        |> put_status(:ok)
        |> json(%{
          message: format_message(message)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Message not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You cannot edit this message"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to edit message: #{inspect(reason)}"})
    end
  end

  def update(conn, %{"id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: content"})
  end

  @doc """
  DELETE /api/messages/:id
  Deletes a message (soft delete).
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]
    message_id = String.to_integer(id)

    # Check if user is admin (for admin delete)
    is_admin = Map.get(user, :is_admin, false) or Map.get(user, :admin, false)

    case Messaging.delete_chat_message(message_id, user.id, is_admin) do
      {:ok, _message} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Message deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Message not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You can only delete your own messages"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to delete message: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/messages/:id/reactions
  Adds a reaction to a message.

  Params:
    - emoji: The emoji to react with (required)
  """
  def add_reaction(conn, %{"message_id" => id, "emoji" => emoji}) do
    user = conn.assigns[:current_user]
    message_id = String.to_integer(id)

    case Messaging.add_chat_reaction(message_id, user.id, emoji) do
      {:ok, reaction} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Reaction added",
          reaction: format_reaction(reaction)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Message not found"})

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "You're adding reactions too quickly"})

      {:error, :already_exists} ->
        # Toggle behavior - remove the reaction
        case Messaging.remove_chat_reaction(message_id, user.id, emoji) do
          {:ok, _} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Reaction removed"})

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to toggle reaction"})
        end

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to add reaction: #{inspect(reason)}"})
    end
  end

  def add_reaction(conn, %{"message_id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: emoji"})
  end

  @doc """
  DELETE /api/messages/:id/reactions/:emoji
  Removes a reaction from a message.
  """
  def remove_reaction(conn, %{"message_id" => id, "emoji" => emoji}) do
    user = conn.assigns[:current_user]
    message_id = String.to_integer(id)

    # URL decode emoji (emojis may be encoded)
    decoded_emoji = URI.decode(emoji)

    case Messaging.remove_chat_reaction(message_id, user.id, decoded_emoji) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Reaction removed"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Reaction not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to remove reaction: #{inspect(reason)}"})
    end
  end

  # Private helpers

  defp format_message(message) do
    %{
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      media_urls: message.media_urls || [],
      media_metadata: message.media_metadata || %{},
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      sender: format_user(message.sender),
      reply_to_id: message.reply_to_id,
      reply_to: format_reply_to(message.reply_to),
      like_count: Map.get(message, :like_count, 0) || 0,
      reply_count: Map.get(message, :reply_count, 0) || 0,
      reactions: format_reactions(message.reactions),
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      created_at: message.inserted_at
    }
  end

  defp format_reply_to(nil), do: nil
  defp format_reply_to(%Ecto.Association.NotLoaded{}), do: nil

  defp format_reply_to(message) do
    %{
      id: message.id,
      content: message.content,
      sender_id: message.sender_id,
      sender: format_user(message.sender)
    }
  end

  defp format_reactions(nil), do: []
  defp format_reactions(%Ecto.Association.NotLoaded{}), do: []

  defp format_reactions(reactions) when is_list(reactions) do
    # Return individual reactions for iOS compatibility
    Enum.map(reactions, fn reaction ->
      # Handle both ChatMessageReaction (chat_message_id) and MessageReaction (message_id)
      message_id =
        cond do
          Map.has_key?(reaction, :chat_message_id) -> reaction.chat_message_id
          Map.has_key?(reaction, :message_id) -> reaction.message_id
          true -> nil
        end

      %{
        id: reaction.id,
        emoji: reaction.emoji,
        user_id: reaction.user_id,
        message_id: message_id
      }
    end)
  end

  defp format_reaction(reaction) do
    %{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      emoji: reaction.emoji,
      created_at: reaction.inserted_at
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

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
end
