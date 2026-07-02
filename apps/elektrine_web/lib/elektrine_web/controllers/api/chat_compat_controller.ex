defmodule ElektrineWeb.API.ChatCompatController do
  @moduledoc """
  Compatibility API for chat-shaped clients, backed by Elektrine chat conversations.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{ChatConversation, ChatConversationMember, ChatMessage}
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON

  action_fallback ElektrineWeb.FallbackController

  def create_by_account(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, account_id} <- parse_id(id),
         %User{} <- Repo.get(User, account_id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.create_dm_conversation(user.id, account_id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation.id, user.id) do
      conn
      |> put_status(:created)
      |> json(format_chat(conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  def index(conn, params) do
    user = conn.assigns[:current_user]

    chats =
      user.id
      |> Messaging.list_chat_conversations(type: "dm", limit: parse_int(params["limit"], 20))
      |> Enum.map(&format_chat(&1, user.id))

    json(conn, chats)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation) do
      json(conn, format_chat(conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  def messages(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation) do
      page = Messaging.get_conversation_messages(conversation_id, user.id, message_opts(params))
      json(conn, Enum.map(page.messages, &format_message/1))
    else
      _ -> not_found(conn)
    end
  end

  def post_message(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation),
         content when is_binary(content) <- text_param(params),
         {:ok, %ChatMessage{} = message} <-
           Messaging.create_text_message(conversation_id, user.id, content) do
      conn
      |> put_status(:created)
      |> json(format_message(message))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})

      _ ->
        not_found(conn)
    end
  end

  def delete_message(conn, %{"id" => id, "message_id" => message_id}) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, message_id} <- parse_id(message_id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation),
         %ChatMessage{conversation_id: ^conversation_id} <- Repo.get(ChatMessage, message_id),
         {:ok, %ChatMessage{} = message} <- Messaging.delete_message(message_id, user.id) do
      json(conn, format_message(message))
    else
      _ -> not_found(conn)
    end
  end

  def read(conn, %{"id" => id}) do
    mark_read(conn, id, nil)
  end

  def read_message(conn, %{"id" => id, "message_id" => message_id}) do
    mark_read(conn, id, message_id)
  end

  def pin(conn, %{"id" => id}) do
    set_pin(conn, id, true)
  end

  def unpin(conn, %{"id" => id}) do
    set_pin(conn, id, false)
  end

  defp mark_read(conn, id, message_id) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation),
         {:ok, parsed_message_id} <- optional_id(message_id),
         {:ok, _result} <- update_read(conversation_id, user.id, parsed_message_id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id) do
      json(conn, format_chat(conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  defp update_read(conversation_id, user_id, nil),
    do: Messaging.mark_as_read(conversation_id, user_id)

  defp update_read(conversation_id, user_id, message_id),
    do: Messaging.update_last_read_message(conversation_id, user_id, message_id)

  defp set_pin(conn, id, pinned) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- dm?(conversation),
         {:ok, %ChatConversationMember{}} <- pin_action(pinned, conversation_id, user.id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id) do
      json(conn, format_chat(conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  defp pin_action(true, conversation_id, user_id),
    do: Messaging.pin_conversation(conversation_id, user_id)

  defp pin_action(false, conversation_id, user_id),
    do: Messaging.unpin_conversation(conversation_id, user_id)

  defp dm?(%ChatConversation{type: "dm"}), do: true
  defp dm?(_conversation), do: false

  defp format_chat(%ChatConversation{} = conversation, user_id) do
    member = Enum.find(conversation.members || [], &(&1.user_id == user_id))
    last_message = conversation.messages |> List.wrap() |> List.first()

    %{
      id: to_string(conversation.id),
      unread: unread?(member, last_message, user_id),
      pinned: pinned?(member),
      updated_at: conversation.last_message_at || conversation.updated_at,
      account: other_account(conversation, user_id),
      last_message: format_message(last_message)
    }
  end

  defp other_account(%ChatConversation{members: members}, user_id) do
    members
    |> List.wrap()
    |> Enum.map(& &1.user)
    |> Enum.reject(&(is_nil(&1) or &1.id == user_id))
    |> List.first()
    |> AccountJSON.format_account(user_id)
  end

  defp format_message(%ChatMessage{} = message) do
    %{
      id: to_string(message.id),
      chat_id: to_string(message.conversation_id),
      account_id: maybe_to_string(message.sender_id),
      content: message.content || "",
      created_at: message.inserted_at,
      emojis: [],
      attachment: nil,
      media_attachments: Enum.map(message.media_urls || [], &format_media/1)
    }
  end

  defp format_message(_message), do: nil

  defp format_media(url) do
    %{id: url, type: "unknown", url: url, preview_url: url, description: nil}
  end

  defp unread?(nil, _message, _user_id), do: false
  defp unread?(_member, nil, _user_id), do: false

  defp unread?(%ChatConversationMember{last_read_at: nil}, %ChatMessage{} = message, user_id),
    do: message.sender_id != user_id

  defp unread?(
         %ChatConversationMember{last_read_at: last_read_at},
         %ChatMessage{} = message,
         _user_id
       ) do
    DateTime.compare(to_datetime(message.inserted_at), to_datetime(last_read_at)) == :gt
  end

  defp pinned?(%ChatConversationMember{pinned: pinned}), do: pinned || false
  defp pinned?(_member), do: false

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp message_opts(params) do
    [
      limit: parse_int(params["limit"], 20),
      before_id: parse_int(params["max_id"], nil),
      after_id: parse_int(params["since_id"] || params["min_id"], nil)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp text_param(%{"content" => content}) when is_binary(content), do: content
  defp text_param(%{"text" => content}) when is_binary(content), do: content
  defp text_param(%{"message" => content}) when is_binary(content), do: content
  defp text_param(_params), do: nil

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(value), do: parse_id(value)

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_value, default), do: default

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end
end
