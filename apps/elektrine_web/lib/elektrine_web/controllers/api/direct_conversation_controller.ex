defmodule ElektrineWeb.API.DirectConversationController do
  @moduledoc """
  API surface for direct conversations.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Messaging
  alias Elektrine.Messaging.{ChatConversation, ChatMessage}
  alias ElektrineWeb.API.AccountJSON

  action_fallback ElektrineWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)

    conversations =
      user.id
      |> Messaging.list_chat_conversations(type: "dm", limit: limit)
      |> Enum.map(&format_conversation(&1, user.id))

    json(conn, conversations)
  end

  def read(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- direct_conversation?(conversation),
         :ok <- Messaging.mark_chat_messages_read(conversation_id, user.id),
         {:ok, %ChatConversation{} = updated_conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id) do
      json(conn, format_conversation(updated_conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  def read_all(conn, _params) do
    user = conn.assigns[:current_user]

    user.id
    |> Messaging.list_chat_conversations(type: "dm", limit: :all)
    |> Enum.each(&Messaging.mark_chat_messages_read(&1.id, user.id))

    index(conn, %{"limit" => "100"})
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- direct_conversation?(conversation) do
      json(conn, format_conversation(conversation, user.id))
    else
      _ -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, recipient_ids} <- parse_recipient_ids(params["recipients"] || params[:recipients]),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- direct_conversation?(conversation),
         :ok <- validate_recipients(conversation, user.id, recipient_ids) do
      json(conn, format_conversation(conversation, user.id))
    else
      {:error, :missing_recipients} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "recipients is required"})

      {:error, :invalid_recipients} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "recipients must match the current direct conversation accounts"})

      _ ->
        not_found(conn)
    end
  end

  def statuses(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- direct_conversation?(conversation) do
      page = Messaging.get_conversation_messages(conversation_id, user.id, message_opts(params))

      conn
      |> put_status(:ok)
      |> put_pagination_headers(conversation_id, page, params)
      |> json(Enum.map(page.messages, &format_message/1))
    else
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, conversation_id} <- parse_id(id),
         {:ok, %ChatConversation{} = conversation} <-
           Messaging.get_chat_conversation!(conversation_id, user.id),
         true <- direct_conversation?(conversation),
         {:ok, _member_or_message} <-
           Messaging.remove_member_from_conversation(conversation_id, user.id) do
      json(conn, %{id: to_string(conversation_id), deleted: true})
    else
      _ -> not_found(conn)
    end
  end

  defp direct_conversation?(%ChatConversation{type: "dm"}), do: true
  defp direct_conversation?(_), do: false

  defp validate_recipients(%ChatConversation{} = conversation, user_id, recipient_ids) do
    expected_ids =
      conversation.members
      |> Enum.reject(& &1.left_at)
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&(&1 == user_id))
      |> MapSet.new()

    received_ids =
      recipient_ids
      |> Enum.reject(&(&1 == user_id))
      |> MapSet.new()

    if MapSet.equal?(expected_ids, received_ids) and MapSet.size(received_ids) > 0 do
      :ok
    else
      {:error, :invalid_recipients}
    end
  end

  defp format_conversation(%ChatConversation{} = conversation, user_id) do
    accounts =
      conversation.members
      |> Enum.map(& &1.user)
      |> Enum.reject(&(is_nil(&1) or &1.id == user_id))
      |> AccountJSON.format_accounts(user_id)

    last_message = conversation.messages |> List.wrap() |> List.first()

    %{
      id: to_string(conversation.id),
      unread: unread?(conversation, user_id, last_message),
      accounts: accounts,
      last_status: format_message(last_message),
      updated_at: conversation.last_message_at || conversation.updated_at
    }
  end

  defp format_message(%ChatMessage{} = message) do
    %{
      id: to_string(message.id),
      content: message.content || "",
      created_at: message.inserted_at,
      media_attachments: Enum.map(message.media_urls || [], &format_media/1)
    }
  end

  defp format_message(_), do: nil

  defp format_media(url) do
    %{
      id: url,
      type: "unknown",
      url: url,
      preview_url: url,
      description: nil
    }
  end

  defp put_pagination_headers(conn, conversation_id, page, params) do
    links =
      []
      |> maybe_put_link(page.has_more_older, "next", conversation_id, params,
        max_id: page.oldest_id
      )
      |> maybe_put_link(page.has_more_newer, "prev", conversation_id, params,
        min_id: page.newest_id
      )

    case links do
      [] -> conn
      links -> put_resp_header(conn, "link", Enum.join(Enum.reverse(links), ", "))
    end
  end

  defp maybe_put_link(links, true, rel, conversation_id, params, cursor) do
    [{param, value}] = cursor

    query =
      params
      |> Map.drop(["id", "max_id", "since_id", "min_id"])
      |> Map.put(to_string(param), value)

    href = "/api/v1/conversations/#{conversation_id}/statuses?#{URI.encode_query(query)}"
    ["<#{href}>; rel=\"#{rel}\"" | links]
  end

  defp maybe_put_link(links, _condition, _rel, _conversation_id, _params, _cursor), do: links

  defp message_opts(params) do
    [
      limit: parse_int(params["limit"], 20),
      before_id: parse_int(params["max_id"], nil),
      after_id: parse_int(params["since_id"] || params["min_id"], nil)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp unread?(%ChatConversation{members: members}, user_id, %ChatMessage{} = message) do
    member = Enum.find(members, &(&1.user_id == user_id))

    cond do
      is_nil(member) ->
        false

      is_nil(member.last_read_at) ->
        message.sender_id != user_id

      is_nil(message.inserted_at) ->
        false

      true ->
        DateTime.compare(to_datetime(message.inserted_at), to_datetime(member.last_read_at)) ==
          :gt
    end
  end

  defp unread?(_, _, _), do: false

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_id}

  defp parse_recipient_ids(nil), do: {:error, :missing_recipients}

  defp parse_recipient_ids(recipients) do
    ids =
      recipients
      |> List.wrap()
      |> Enum.flat_map(fn
        value when is_binary(value) -> String.split(value, ",", trim: true)
        value -> [value]
      end)
      |> Enum.map(&parse_id/1)

    if Enum.all?(ids, &match?({:ok, _}, &1)) do
      {:ok, ids |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()}
    else
      {:error, :invalid_recipients}
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "conversation not found"})
  end
end
