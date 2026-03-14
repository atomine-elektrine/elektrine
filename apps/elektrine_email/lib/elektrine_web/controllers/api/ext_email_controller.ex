defmodule ElektrineWeb.API.ExtEmailController do
  @moduledoc """
  External API controller for read-only email access.
  """

  use ElektrineEmailWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Email
  alias Elektrine.Email.{Mailbox, Message}
  alias Elektrine.Repo
  alias ElektrineWeb.API.Response

  @default_limit 20
  @max_limit 100
  @default_folder "all"
  @valid_folders ~w(all inbox feed ledger stack reply_later sent drafts spam trash archived)

  @doc """
  GET /api/ext/v1/email/messages
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)
    offset = parse_non_negative_int(params["offset"], 0)
    folder = params["folder"] || @default_folder

    with {:ok, mailbox_filter} <- resolve_mailbox_filter(user.id, params["mailbox_id"]),
         {:ok, query} <- build_query(user.id, mailbox_filter, folder) do
      total_count = Repo.aggregate(query, :count, :id)

      messages =
        query
        |> order_messages(folder)
        |> preload([_message, mailbox], mailbox: mailbox)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> Message.decrypt_messages(user.id)

      Response.ok(
        conn,
        %{messages: Enum.map(messages, &format_message_summary/1)},
        %{
          pagination: %{limit: limit, offset: offset, total_count: total_count},
          filters: mailbox_filter_meta(mailbox_filter, folder)
        }
      )
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid mailbox id")

      {:error, :mailbox_not_found} ->
        Response.error(conn, :not_found, "not_found", "Mailbox not found")

      {:error, :invalid_folder} ->
        Response.error(conn, :bad_request, "invalid_folder", "Invalid folder filter")
    end
  end

  @doc """
  GET /api/ext/v1/email/messages/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, message_id} <- parse_id(id),
         {:ok, message} <- Email.get_user_message(message_id, user.id) do
      message = Repo.preload(message, :mailbox)
      Response.ok(conn, %{message: format_message_detail(message)})
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid message id")

      {:error, :message_not_found} ->
        Response.error(conn, :not_found, "not_found", "Message not found")

      {:error, :mailbox_not_found} ->
        Response.error(conn, :not_found, "not_found", "Message not found")

      {:error, :access_denied} ->
        Response.error(conn, :not_found, "not_found", "Message not found")
    end
  end

  defp build_query(user_id, mailbox_filter, folder) do
    if folder in @valid_folders do
      query =
        from(message in Message,
          join: mailbox in Mailbox,
          on: mailbox.id == message.mailbox_id,
          where: mailbox.user_id == ^user_id
        )

      query =
        case mailbox_filter do
          {:mailbox_id, mailbox_id} ->
            from([message, _mailbox] in query, where: message.mailbox_id == ^mailbox_id)

          :all ->
            query
        end

      {:ok, apply_folder_filter(query, folder)}
    else
      {:error, :invalid_folder}
    end
  end

  defp apply_folder_filter(query, "all"), do: query

  defp apply_folder_filter(query, "inbox") do
    from([message, _mailbox] in query,
      where:
        not message.spam and
          not message.archived and
          not message.deleted and
          (message.status not in ["sent", "draft"] or is_nil(message.status) or
             message.from == message.to) and
          message.category not in ["feed", "ledger", "stack"] and
          is_nil(message.reply_later_at) and
          is_nil(message.folder_id)
    )
  end

  defp apply_folder_filter(query, "feed") do
    from([message, _mailbox] in query,
      where:
        message.category == "feed" and
          not message.spam and
          not message.archived and
          not message.deleted and
          (message.status not in ["sent", "draft"] or is_nil(message.status) or
             message.from == message.to)
    )
  end

  defp apply_folder_filter(query, "ledger") do
    from([message, _mailbox] in query,
      where:
        message.category == "ledger" and
          not message.spam and
          not message.archived and
          not message.deleted and
          (message.status not in ["sent", "draft"] or is_nil(message.status) or
             message.from == message.to)
    )
  end

  defp apply_folder_filter(query, "stack") do
    from([message, _mailbox] in query,
      where:
        message.category == "stack" and
          not is_nil(message.stack_at) and
          not message.spam and
          not message.archived and
          not message.deleted and
          (message.status not in ["sent", "draft"] or is_nil(message.status) or
             message.from == message.to)
    )
  end

  defp apply_folder_filter(query, "reply_later") do
    from([message, _mailbox] in query,
      where:
        not is_nil(message.reply_later_at) and
          not message.spam and
          not message.archived and
          not message.deleted and
          (message.status not in ["sent", "draft"] or is_nil(message.status) or
             message.from == message.to)
    )
  end

  defp apply_folder_filter(query, "sent") do
    from([message, _mailbox] in query,
      where:
        message.status == "sent" and
          not message.archived and
          not message.deleted and
          is_nil(message.folder_id)
    )
  end

  defp apply_folder_filter(query, "drafts") do
    from([message, _mailbox] in query,
      where: message.status == "draft" and not message.deleted and is_nil(message.folder_id)
    )
  end

  defp apply_folder_filter(query, "spam") do
    from([message, _mailbox] in query,
      where:
        message.spam and not message.archived and not message.deleted and
          is_nil(message.folder_id)
    )
  end

  defp apply_folder_filter(query, "trash") do
    from([message, _mailbox] in query, where: message.deleted)
  end

  defp apply_folder_filter(query, "archived") do
    from([message, _mailbox] in query,
      where: message.archived and not message.deleted and is_nil(message.folder_id)
    )
  end

  defp order_messages(query, "stack") do
    from([message, _mailbox] in query,
      order_by: [desc: message.stack_at, desc: message.inserted_at]
    )
  end

  defp order_messages(query, "reply_later") do
    from([message, _mailbox] in query,
      order_by: [asc: message.reply_later_at, desc: message.inserted_at]
    )
  end

  defp order_messages(query, "drafts") do
    from([message, _mailbox] in query, order_by: [desc: message.updated_at])
  end

  defp order_messages(query, _folder) do
    from([message, _mailbox] in query, order_by: [desc: message.inserted_at])
  end

  defp resolve_mailbox_filter(_user_id, nil), do: {:ok, :all}
  defp resolve_mailbox_filter(_user_id, ""), do: {:ok, :all}

  defp resolve_mailbox_filter(user_id, mailbox_id) do
    with {:ok, parsed_mailbox_id} <- parse_id(mailbox_id),
         %Mailbox{} <- Email.get_mailbox(parsed_mailbox_id, user_id) do
      {:ok, {:mailbox_id, parsed_mailbox_id}}
    else
      {:error, :invalid_id} -> {:error, :invalid_id}
      nil -> {:error, :mailbox_not_found}
    end
  end

  defp mailbox_filter_meta(:all, folder), do: %{folder: folder}

  defp mailbox_filter_meta({:mailbox_id, mailbox_id}, folder) do
    %{folder: folder, mailbox_id: mailbox_id}
  end

  defp format_message_summary(message) do
    %{
      id: message.id,
      message_id: message.message_id,
      from: message.from,
      to: message.to,
      subject: message.subject,
      preview: message_preview(message),
      status: message.status,
      read: message.read,
      spam: message.spam,
      archived: message.archived,
      deleted: message.deleted,
      category: format_category(message.category),
      has_attachments: message.has_attachments,
      attachments_count: attachment_count(message.attachments),
      private_encrypted: Message.private_encrypted?(message),
      mailbox: format_mailbox(message.mailbox),
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp format_message_detail(message) do
    format_message_summary(message)
    |> Map.merge(%{
      cc: message.cc,
      bcc: message.bcc,
      text_body: message.text_body,
      html_body: message.html_body,
      attachments: format_attachments(message.attachments),
      metadata: message.metadata || %{}
    })
  end

  defp message_preview(%Message{text_body: text_body})
       when is_binary(text_body) and text_body != "" do
    text_body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp message_preview(%Message{html_body: html_body})
       when is_binary(html_body) and html_body != "" do
    html_body
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp message_preview(_message), do: nil

  defp format_mailbox(%Mailbox{} = mailbox) do
    %{
      id: mailbox.id,
      email: mailbox.email,
      username: mailbox.username
    }
  end

  defp format_mailbox(%Ecto.Association.NotLoaded{}), do: nil
  defp format_mailbox(nil), do: nil

  defp format_attachments(attachments) when is_map(attachments) do
    Enum.map(attachments, fn {id, attachment} ->
      format_attachment(id, attachment)
    end)
  end

  defp format_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn attachment ->
      id = Map.get(attachment, "id") || Map.get(attachment, :id)
      format_attachment(id, attachment)
    end)
  end

  defp format_attachments(_attachments), do: []

  defp format_attachment(id, attachment) when is_map(attachment) do
    %{
      id: id,
      filename: Map.get(attachment, "filename") || Map.get(attachment, :filename),
      content_type: Map.get(attachment, "content_type") || Map.get(attachment, :content_type),
      size: Map.get(attachment, "size") || Map.get(attachment, :size),
      disposition: Map.get(attachment, "disposition") || Map.get(attachment, :disposition)
    }
  end

  defp format_attachment(id, _attachment), do: %{id: id}

  defp attachment_count(attachments) when is_map(attachments), do: map_size(attachments)
  defp attachment_count(attachments) when is_list(attachments), do: length(attachments)
  defp attachment_count(_attachments), do: 0

  defp format_category("paper_pile"), do: "feed"
  defp format_category("important_stuff"), do: "ledger"
  defp format_category("random_stuff"), do: "stack"
  defp format_category(nil), do: "inbox"
  defp format_category(category) when is_binary(category), do: category
  defp format_category(_category), do: "inbox"

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_value, default), do: default
end
