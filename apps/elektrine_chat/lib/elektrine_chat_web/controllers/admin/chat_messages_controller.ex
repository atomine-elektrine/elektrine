defmodule ElektrineChatWeb.Admin.ChatMessagesController do
  @moduledoc """
  Controller for admin Arblarg chat message viewing and management.
  """

  use ElektrineChatWeb, :controller

  alias Elektrine.{Messaging, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone, do: current_user.timezone, else: "Etc/UTC"

    time_format =
      if current_user && current_user.time_format, do: current_user.time_format, else: "12"

    conn
    |> assign(:timezone, timezone)
    |> assign(:time_format, time_format)
  end

  def index(conn, params) do
    search_query = params |> Map.get("search", "") |> String.trim()

    conversation_type_filter =
      parse_conversation_type_filter(Map.get(params, "conversation_type"))

    protocol_filter = parse_protocol_filter(Map.get(params, "protocol"))
    page = SafeConvert.parse_page(params)
    per_page = 50
    offset = (page - 1) * per_page

    query =
      base_chat_messages_query()
      |> maybe_filter_conversation_type(conversation_type_filter)
      |> maybe_filter_protocol(protocol_filter)
      |> maybe_search(search_query)

    total_count =
      query
      |> exclude(:order_by)
      |> select([m, ...], m.id)
      |> Repo.aggregate(:count, :id)

    messages =
      query
      |> order_by([m], desc: m.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload([_m, c, s], conversation: c, sender: s)
      |> Repo.all()
      |> Messaging.ChatMessage.decrypt_messages()
      |> Enum.map(&Map.put(&1, :protocol_kind, protocol_kind(&1)))

    stats = %{
      local: Enum.count(messages, &(&1.protocol_kind == "local")),
      federated: Enum.count(messages, &(&1.protocol_kind == "federated")),
      mirrored: Enum.count(messages, &(&1.protocol_kind == "mirrored"))
    }

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    log_admin_chat_messages_index(
      conn,
      messages,
      page,
      search_query,
      conversation_type_filter,
      protocol_filter
    )

    render(conn, :chat_messages,
      messages: messages,
      search_query: search_query,
      conversation_type_filter: conversation_type_filter,
      protocol_filter: protocol_filter,
      page_results_count: length(messages),
      stats: stats,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def view(conn, %{"id" => message_id}) do
    case SafeConvert.parse_id(message_id) do
      {:ok, id} ->
        case Messaging.get_chat_message(id) do
          nil ->
            not_found(conn)

          %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
            not_found(conn)

          message ->
            message =
              message
              |> Repo.preload(:conversation)
              |> Messaging.ChatMessage.decrypt_content()
              |> Map.put(:protocol_kind, protocol_kind(message))

            log_admin_chat_message_view(conn, message, "html", "admin_arblarg_messages")

            render(conn, :view_chat_message, message: message)
        end

      {:error, _} ->
        not_found(conn)
    end
  end

  def view_raw(conn, %{"id" => message_id}) do
    case SafeConvert.parse_id(message_id) do
      {:ok, id} ->
        case Messaging.get_chat_message(id) do
          nil ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(404, "Chat message not found")

          %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(404, "Chat message not found")

          message ->
            message =
              message
              |> Repo.preload(:conversation)
              |> Messaging.ChatMessage.decrypt_content()
              |> Map.put(:protocol_kind, protocol_kind(message))

            log_admin_chat_message_view(conn, message, "raw", "admin_arblarg_messages")

            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, get_raw_chat_message_content(message))
        end

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Chat message not found")
    end
  end

  defp not_found(conn) do
    conn
    |> put_flash(:error, "Chat message not found")
    |> redirect(to: ~p"/pripyat/arblarg/messages")
  end

  defp base_chat_messages_query do
    from(m in Messaging.ChatMessage,
      left_join: c in Messaging.Conversation,
      on: m.conversation_id == c.id,
      left_join: s in Elektrine.Accounts.User,
      on: m.sender_id == s.id,
      where: is_nil(m.deleted_at)
    )
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search_query) do
    search_term = "%#{search_query}%"

    from([m, c, s] in query,
      where:
        ilike(fragment("COALESCE(?, '')", m.content), ^search_term) or
          ilike(fragment("COALESCE(?, '')", s.username), ^search_term) or
          ilike(fragment("COALESCE(?, '')", s.handle), ^search_term) or
          ilike(fragment("COALESCE(?, '')", c.name), ^search_term) or
          ilike(fragment("COALESCE(?, '')", m.federated_source), ^search_term) or
          ilike(fragment("COALESCE(?, '')", m.origin_domain), ^search_term)
    )
  end

  defp maybe_filter_conversation_type(query, "dm"), do: where(query, [_m, c, _s], c.type == "dm")

  defp maybe_filter_conversation_type(query, "group"),
    do: where(query, [_m, c, _s], c.type == "group")

  defp maybe_filter_conversation_type(query, "channel"),
    do: where(query, [_m, c, _s], c.type == "channel")

  defp maybe_filter_conversation_type(query, "all"), do: query
  defp maybe_filter_conversation_type(query, _), do: query

  defp maybe_filter_protocol(query, "local"),
    do:
      where(
        query,
        [m, _c, _s],
        is_nil(m.federated_source) and is_nil(m.origin_domain) and m.is_federated_mirror == false
      )

  defp maybe_filter_protocol(query, "mirrored"),
    do: where(query, [m, _c, _s], m.is_federated_mirror == true)

  defp maybe_filter_protocol(query, "federated"),
    do:
      where(
        query,
        [m, _c, _s],
        not is_nil(m.federated_source) or not is_nil(m.origin_domain) or
          m.is_federated_mirror == true
      )

  defp maybe_filter_protocol(query, "all"), do: query
  defp maybe_filter_protocol(query, _), do: query

  defp parse_conversation_type_filter("dm"), do: "dm"
  defp parse_conversation_type_filter("group"), do: "group"
  defp parse_conversation_type_filter("channel"), do: "channel"
  defp parse_conversation_type_filter(_), do: "all"

  defp parse_protocol_filter("local"), do: "local"
  defp parse_protocol_filter("federated"), do: "federated"
  defp parse_protocol_filter("mirrored"), do: "mirrored"
  defp parse_protocol_filter(_), do: "all"

  defp protocol_kind(message) do
    cond do
      message.is_federated_mirror -> "mirrored"
      present?(message.federated_source) or present?(message.origin_domain) -> "federated"
      true -> "local"
    end
  end

  defp present?(value), do: Elektrine.Strings.present?(value)

  defp get_raw_chat_message_content(message) do
    conversation = Map.get(message, :conversation)
    sender = Map.get(message, :sender)

    media_urls =
      message.media_urls
      |> List.wrap()
      |> Enum.join("\n")
      |> case do
        "" -> "(No media URLs)"
        value -> value
      end

    media_metadata =
      case message.media_metadata do
        value when is_map(value) and map_size(value) > 0 -> Jason.encode!(value, pretty: true)
        _ -> "(No media metadata)"
      end

    """
    ===============================================================================
    ARBLARG CHAT MESSAGE
    ===============================================================================

    MESSAGE FIELDS:
    ---------------
    ID: #{message.id}
    Message Type: #{message.message_type || "text"}
    Protocol Kind: #{message.protocol_kind}
    Conversation ID: #{message.conversation_id || "N/A"}
    Sender ID: #{message.sender_id || "N/A"}
    Reply To ID: #{message.reply_to_id || "(None)"}
    Federated Source: #{message.federated_source || "(None)"}
    Origin Domain: #{message.origin_domain || "(None)"}
    Mirrored: #{message.is_federated_mirror || false}
    Edited At: #{message.edited_at || "(Never)"}
    Inserted At: #{message.inserted_at}
    Updated At: #{message.updated_at}

    CONVERSATION:
    -------------
    #{if conversation do
      """
      Name: #{conversation.name || "(No name)"}
      Type: #{conversation.type || "(Unknown)"}
      Public: #{conversation.is_public || false}
      Hash: #{conversation.hash || "(No hash)"}
      """
    else
      "Conversation not loaded"
    end}

    SENDER:
    -------
    #{if sender do
      """
      Username: #{sender.username}
      Handle: #{sender.handle || "(No handle)"}
      Is Admin: #{sender.is_admin || false}
      """
    else
      "Sender not loaded"
    end}

    CONTENT:
    --------
    #{message.content || "(No text content)"}

    MEDIA URLS:
    -----------
    #{media_urls}

    MEDIA METADATA:
    ---------------
    #{media_metadata}

    RAW STRUCT:
    -----------
    #{inspect(message, pretty: true, limit: :infinity)}

    ===============================================================================
    END OF ARBLARG CHAT MESSAGE
    ===============================================================================
    """
  end

  defp log_admin_chat_messages_index(
         conn,
         messages,
         page,
         search_query,
         conversation_type_filter,
         protocol_filter
       ) do
    case conn.assigns[:current_user] do
      %{id: admin_id, is_admin: true, username: admin_username} ->
        Elektrine.AuditLog.log(
          admin_id,
          "view_chat_messages",
          "chat_message_list",
          details: %{
            route_context: "admin_arblarg_messages",
            page: page,
            search_query: search_query,
            conversation_type_filter: conversation_type_filter,
            protocol_filter: protocol_filter,
            result_count: length(messages),
            message_ids: Enum.map(messages, & &1.id),
            viewer_username: admin_username
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

      _ ->
        :ok
    end
  end

  defp log_admin_chat_message_view(conn, message, view_format, route_context) do
    case conn.assigns[:current_user] do
      %{id: admin_id, is_admin: true, username: admin_username} ->
        Elektrine.AuditLog.log(
          admin_id,
          "view_chat_message",
          "chat_message",
          target_user_id: message.sender_id,
          resource_id: message.id,
          details: %{
            view_format: view_format,
            route_context: route_context,
            message_type: message.message_type,
            conversation_id: message.conversation_id,
            conversation_type: message.conversation && message.conversation.type,
            protocol_kind: message.protocol_kind,
            federated_source: message.federated_source,
            origin_domain: message.origin_domain,
            mirrored: message.is_federated_mirror || false,
            viewer_username: admin_username
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

      _ ->
        :ok
    end
  end

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages//1 |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        1..7//1 |> Enum.to_list()

      current_page >= total_pages - 3 ->
        (total_pages - 6)..total_pages//1 |> Enum.to_list()

      true ->
        (current_page - 3)..(current_page + 3)//1 |> Enum.to_list()
    end
  end
end
