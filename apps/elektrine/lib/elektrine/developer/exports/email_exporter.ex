defmodule Elektrine.Developer.Exports.EmailExporter do
  @moduledoc """
  Exports user's email messages in various formats.

  Supported formats:
  - json: JSON format (most complete)
  - mbox: Standard mbox format for email clients
  - zip: Compressed archive
  """

  import Ecto.Query
  alias Elektrine.Email.Message
  alias Elektrine.Repo

  @doc """
  Exports all emails for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export(user_id, file_path, format, filters \\ %{}) do
    # Get user's mailbox
    mailbox = Elektrine.Email.get_user_mailbox(user_id)

    if mailbox do
      messages = fetch_messages(mailbox.id, filters)
      count = length(messages)

      case format do
        "json" -> export_json(messages, file_path)
        "mbox" -> export_mbox(messages, file_path)
        _ -> export_json(messages, file_path)
      end

      {:ok, count}
    else
      # No mailbox, export empty
      File.write!(file_path, "[]")
      {:ok, 0}
    end
  end

  defp fetch_messages(mailbox_id, filters) do
    query =
      from m in Message,
        where: m.mailbox_id == ^mailbox_id and m.deleted == false,
        order_by: [desc: m.inserted_at],
        select: m

    query = apply_filters(query, filters)

    Repo.all(query)
  end

  defp apply_filters(query, %{"from_date" => from_date}) when is_binary(from_date) do
    case DateTime.from_iso8601(from_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, %{"to_date" => to_date}) when is_binary(to_date) do
    case DateTime.from_iso8601(to_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at <= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, _), do: query

  defp export_json(messages, file_path) do
    data =
      messages
      |> Enum.map(&format_message/1)
      |> Jason.encode!(pretty: true)

    File.write!(file_path, data)
  end

  defp export_mbox(messages, file_path) do
    mbox_content =
      messages
      |> Enum.map_join("\n", &format_mbox_message/1)

    File.write!(file_path, mbox_content)
  end

  defp format_message(message) do
    %{
      id: message.id,
      message_id: message.message_id,
      from: message.from,
      to: message.to,
      cc: message.cc,
      bcc: message.bcc,
      subject: message.subject,
      text_body: message.text_body,
      html_body: message.html_body,
      status: message.status,
      read: message.read,
      spam: message.spam,
      archived: message.archived,
      flagged: message.flagged,
      answered: message.answered,
      category: message.category,
      has_attachments: message.has_attachments,
      attachments: message.attachments,
      in_reply_to: message.in_reply_to,
      references: message.references,
      priority: message.priority,
      metadata: message.metadata,
      created_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp format_mbox_message(message) do
    # Format date for mbox
    date = format_date(message.inserted_at)

    # Build mbox format
    """
    From #{extract_email(message.from)} #{date}
    From: #{message.from}
    To: #{message.to}
    Subject: #{message.subject || "(no subject)"}
    Date: #{date}
    Message-ID: #{message.message_id}
    #{if message.cc, do: "Cc: #{message.cc}\n", else: ""}#{if message.in_reply_to, do: "In-Reply-To: #{message.in_reply_to}\n", else: ""}
    #{message.text_body || ""}
    """
  end

  defp extract_email(from) when is_binary(from) do
    case Regex.run(~r/<([^>]+)>/, from) do
      [_, email] -> email
      _ -> from
    end
  end

  defp extract_email(_), do: "unknown@localhost"

  defp format_date(nil), do: "Mon Jan  1 00:00:00 2000"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%a %b %d %H:%M:%S %Y")
  end
end
