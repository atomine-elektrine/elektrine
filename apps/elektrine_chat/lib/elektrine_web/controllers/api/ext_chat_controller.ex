defmodule ElektrineWeb.API.ExtChatController do
  @moduledoc """
  External API controller for read-only chat access.
  """

  use ElektrineChatWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{ChatMessages, Conversation, ConversationMember}
  alias Elektrine.Repo
  alias ElektrineWeb.API.Response

  @chat_types ~w(dm group channel)
  @default_limit 20
  @max_limit 100
  @default_message_limit 50

  @doc """
  GET /api/ext/v1/chat/conversations
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    conversations =
      list_chat_conversations(user.id, limit)
      |> Enum.map(&with_latest_message(&1, user.id))

    Response.ok(
      conn,
      %{conversations: Enum.map(conversations, &format_conversation(&1, user.id))},
      %{pagination: %{limit: limit, total_count: length(conversations)}}
    )
  end

  @doc """
  GET /api/ext/v1/chat/conversations/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, conversation} <- fetch_chat_conversation(conversation_id, user.id) do
      page =
        ChatMessages.get_conversation_messages(conversation.id, user.id,
          limit: @default_message_limit
        )

      Response.ok(
        conn,
        %{
          conversation: format_conversation(with_latest_message(conversation, user.id), user.id),
          messages: Enum.map(page.messages, &format_message/1)
        },
        %{pagination: pagination_meta(page, @default_message_limit)}
      )
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid conversation id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Conversation not found")
    end
  end

  @doc """
  GET /api/ext/v1/chat/conversations/:id/messages
  """
  def messages(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_message_limit) |> min(@max_limit)

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, before_id} <- parse_optional_id(params["before_id"]),
         {:ok, after_id} <- parse_optional_id(params["after_id"]),
         {:ok, conversation} <- fetch_chat_conversation(conversation_id, user.id) do
      page =
        ChatMessages.get_conversation_messages(conversation.id, user.id,
          limit: limit,
          before_id: before_id,
          after_id: after_id
        )

      Response.ok(
        conn,
        %{messages: Enum.map(page.messages, &format_message/1)},
        %{pagination: pagination_meta(page, limit)}
      )
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid conversation or message id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Conversation not found")
    end
  end

  defp list_chat_conversations(user_id, limit) do
    from(conversation in Conversation,
      join: membership in ConversationMember,
      on: membership.conversation_id == conversation.id and membership.user_id == ^user_id,
      where: is_nil(membership.left_at) and conversation.type in ^@chat_types,
      order_by: [
        desc: membership.pinned,
        desc: conversation.last_message_at,
        desc: conversation.updated_at
      ],
      limit: ^limit,
      preload: [members: [user: [:profile]]]
    )
    |> Repo.all()
    |> Enum.reject(&blocked_dm?(&1, user_id))
  end

  defp fetch_chat_conversation(conversation_id, user_id) do
    case Messaging.get_conversation_for_chat!(conversation_id, user_id) do
      {:ok, %Conversation{type: type} = conversation} when type in @chat_types ->
        if blocked_dm?(conversation, user_id) do
          {:error, :not_found}
        else
          {:ok, conversation}
        end

      {:ok, _conversation} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp with_latest_message(conversation, user_id) do
    latest_message =
      conversation.id
      |> ChatMessages.get_messages(user_id: user_id, limit: 1)
      |> List.first()

    Map.put(conversation, :latest_message, latest_message)
  end

  defp blocked_dm?(%Conversation{type: "dm", members: members}, user_id) when is_list(members) do
    case Enum.find(members, fn member ->
           member.user_id != user_id and is_nil(member.left_at)
         end) do
      %{user_id: other_user_id} ->
        Accounts.user_blocked?(user_id, other_user_id) or
          Accounts.user_blocked?(other_user_id, user_id)

      _ ->
        false
    end
  end

  defp blocked_dm?(_conversation, _user_id), do: false

  defp format_conversation(conversation, current_user_id) do
    members =
      conversation.members
      |> List.wrap()
      |> Enum.filter(&is_nil(&1.left_at))
      |> Enum.map(&format_member/1)

    %{
      id: conversation.id,
      type: conversation.type,
      name: Conversation.display_name(conversation, current_user_id),
      description: conversation.description,
      avatar_url: Conversation.avatar_url(conversation, current_user_id),
      is_public: conversation.is_public,
      member_count: length(members),
      last_message_at: conversation.last_message_at,
      latest_message: format_message_preview(Map.get(conversation, :latest_message)),
      members: members
    }
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

  defp format_message_preview(nil), do: nil

  defp format_message_preview(message) do
    %{
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      sender: format_user(message.sender),
      inserted_at: message.inserted_at,
      edited_at: message.edited_at
    }
  end

  defp format_message(message) do
    %{
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      media_urls: message.media_urls || [],
      media_metadata: message.media_metadata || %{},
      sender_id: message.sender_id,
      sender: format_user(message.sender),
      reply_to_id: message.reply_to_id,
      reply_to: format_reply_to(message.reply_to),
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at
    }
  end

  defp format_reply_to(nil), do: nil
  defp format_reply_to(%Ecto.Association.NotLoaded{}), do: nil

  defp format_reply_to(message) do
    %{
      id: message.id,
      content: message.content,
      sender: format_user(message.sender)
    }
  end

  defp format_user(nil), do: nil
  defp format_user(%Ecto.Association.NotLoaded{}), do: nil

  defp format_user(user) do
    %{
      id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name,
      avatar: user.avatar
    }
  end

  defp pagination_meta(page, limit) do
    %{
      limit: limit,
      has_more_older: page.has_more_older,
      has_more_newer: page.has_more_newer,
      oldest_id: page.oldest_id,
      newest_id: page.newest_id
    }
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp parse_optional_id(nil), do: {:ok, nil}
  defp parse_optional_id(""), do: {:ok, nil}

  defp parse_optional_id(value) do
    parse_id(value)
  end

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default
end
