defmodule ElektrineWeb.API.EmailController do
  use ElektrineWeb, :controller

  alias Elektrine.Email
  alias Elektrine.Email.{Search, Messages, AttachmentStorage, Folders, Message}

  action_fallback ElektrineWeb.FallbackController
  @default_page 1
  @default_limit 20
  @max_page_size 100

  @doc """
  GET /api/emails
  Lists emails for the current user's mailbox
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]

    # Get user's primary mailbox
    mailbox = Email.get_user_mailbox(user.id)

    if mailbox do
      page = parse_positive_int(Map.get(params, "page"), @default_page)
      limit = parse_positive_int(Map.get(params, "limit"), @default_limit) |> min(@max_page_size)

      folder = Map.get(params, "folder", "inbox")

      # Get paginated messages based on folder
      result =
        case folder do
          "inbox" ->
            Email.Folders.list_inbox_messages_paginated(mailbox.id, page, limit)

          "feed" ->
            Email.Folders.list_feed_messages_paginated(mailbox.id, page, limit)

          "ledger" ->
            Email.Folders.list_ledger_messages_paginated(mailbox.id, page, limit)

          "stack" ->
            Email.Folders.list_stack_messages_paginated(mailbox.id, page, limit)

          "reply_later" ->
            Email.Folders.list_reply_later_messages_paginated(mailbox.id, page, limit)

          "sent" ->
            Email.Folders.list_sent_messages_paginated(mailbox.id, page, limit)

          "spam" ->
            Email.Folders.list_spam_messages_paginated(mailbox.id, page, limit)

          "trash" ->
            Email.Folders.list_trash_messages_paginated(mailbox.id, page, limit)

          "archived" ->
            Email.Folders.list_archived_messages_paginated(mailbox.id, page, limit)

          _ ->
            Email.Folders.list_inbox_messages_paginated(mailbox.id, page, limit)
        end

      conn
      |> put_status(:ok)
      |> json(%{
        emails: Enum.map(result.messages, &format_message/1),
        page: result.page,
        limit: limit,
        total_pages: result.total_pages,
        total_count: result.total_count,
        has_next: result.has_next,
        has_prev: result.has_prev
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  @doc """
  GET /api/emails/:id
  Gets a specific email by ID
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          conn
          |> put_status(:ok)
          |> json(%{email: format_message(message)})

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  @doc """
  POST /api/emails/send
  Sends a new email
  """
  def send_email(conn, %{"email" => email_params}) do
    user = conn.assigns[:current_user]

    # Check rate limit before sending
    case Elektrine.Email.RateLimiter.check_rate_limit(user.id) do
      {:ok, _remaining} ->
        attempt_send_email(conn, user, email_params)

      {:error, :minute_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Rate limit exceeded: maximum 10 emails per minute"})

      {:error, :hourly_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Rate limit exceeded: maximum 100 emails per hour"})

      {:error, :daily_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Rate limit exceeded: maximum 1000 emails per day"})

      {:error, _reason} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Rate limit exceeded"})
    end
  end

  defp attempt_send_email(conn, user, email_params) do
    # Get user's primary mailbox
    mailbox = Email.get_user_mailbox(user.id)

    if mailbox do
      # Build email params
      params =
        %{
          from: mailbox.email,
          to: Map.get(email_params, "to"),
          subject: Map.get(email_params, "subject", ""),
          text_body: Map.get(email_params, "text_body") || Map.get(email_params, "body", ""),
          cc: Map.get(email_params, "cc"),
          bcc: Map.get(email_params, "bcc")
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) || v == "" end)
        |> Map.new()

      # Send email using the Email.Sender module
      case Elektrine.Email.Sender.send_email(user.id, params) do
        {:ok, _message} ->
          conn
          |> put_status(:ok)
          |> json(%{message: "Email sent successfully"})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to send email", reason: inspect(reason)})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  @doc """
  PUT /api/emails/:id
  Updates an email (mark as read, archive, etc.)
  """
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          # Update the message based on params
          result =
            cond do
              Map.has_key?(params, "read") && params["read"] == true ->
                Email.mark_as_read(message)

              Map.has_key?(params, "read") && params["read"] == false ->
                Email.mark_as_unread(message)

              Map.has_key?(params, "archived") && params["archived"] == true ->
                Email.archive_message(message)

              Map.has_key?(params, "archived") && params["archived"] == false ->
                Email.unarchive_message(message)

              Map.has_key?(params, "spam") && params["spam"] == true ->
                Email.mark_as_spam(message)

              Map.has_key?(params, "spam") && params["spam"] == false ->
                Email.mark_as_not_spam(message)

              true ->
                {:ok, message}
            end

          case result do
            {:ok, updated_message} ->
              conn
              |> put_status(:ok)
              |> json(%{
                message: "Email updated successfully",
                email: format_message(updated_message)
              })

            {:error, _changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to update email"})
          end

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  @doc """
  DELETE /api/emails/:id
  Deletes an email
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          case Email.delete_message(message) do
            {:ok, _} ->
              conn
              |> put_status(:ok)
              |> json(%{message: "Email deleted successfully"})

            {:error, _changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to delete email"})
          end

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  @doc """
  GET /api/emails/search
  Searches emails by query string.
  """
  def search(conn, %{"q" => query} = params) do
    user = conn.assigns[:current_user]
    mailbox = Email.get_user_mailbox(user.id)

    if mailbox do
      page = parse_positive_int(params["page"], @default_page)
      # Cap per_page at @max_page_size to prevent DoS via large result sets
      per_page = parse_positive_int(params["per_page"], @default_limit) |> min(@max_page_size)

      result = Search.search_messages(mailbox.id, query, page, per_page)

      conn
      |> put_status(:ok)
      |> json(%{
        emails: Enum.map(result.messages, &format_message/1),
        query: result.query,
        pagination: %{
          page: result.page,
          per_page: result.per_page,
          total: result.total_count,
          total_pages: result.total_pages,
          has_next: result.has_next,
          has_prev: result.has_prev
        }
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: q"})
  end

  @doc """
  GET /api/emails/counts
  Returns unread counts for all folders/categories.
  """
  def counts(conn, _params) do
    user = conn.assigns[:current_user]
    mailbox = Email.get_user_mailbox(user.id)

    if mailbox do
      unread_counts = Messages.get_all_unread_counts(mailbox.id)

      conn
      |> put_status(:ok)
      |> json(%{counts: unread_counts})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  @doc """
  POST /api/emails/bulk
  Performs bulk operations on multiple emails.

  Params:
    - ids: List of email IDs
    - action: One of "mark_read", "mark_unread", "archive", "unarchive", "spam", "not_spam", "delete"
  """
  # Maximum number of IDs allowed in bulk operations to prevent DoS
  @max_bulk_ids 100

  def bulk_action(conn, %{"ids" => ids, "action" => action}) when is_list(ids) do
    user = conn.assigns[:current_user]

    # Limit to @max_bulk_ids to prevent DoS
    limited_ids = Enum.take(ids, @max_bulk_ids)

    # Validate all IDs belong to user
    results =
      limited_ids
      |> Enum.map(&parse_int(&1, nil))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn id ->
        case Email.get_user_message(id, user.id) do
          {:ok, message} -> perform_bulk_action(message, action)
          {:error, _reason} -> {:error, :not_found}
          nil -> {:error, :not_found}
        end
      end)

    success_count =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    error_count = length(results) - success_count

    conn
    |> put_status(:ok)
    |> json(%{
      message: "Bulk operation completed",
      success_count: success_count,
      error_count: error_count
    })
  end

  def bulk_action(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: ids (array), action (string)"})
  end

  @doc """
  GET /api/emails/:id/attachments
  Lists attachments for an email.
  """
  def list_attachments(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          attachments = format_attachments(message.attachments || %{})

          conn
          |> put_status(:ok)
          |> json(%{attachments: attachments})

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  @doc """
  GET /api/emails/:id/attachments/:attachment_id
  Gets a presigned download URL for an attachment.
  """
  def attachment(conn, %{"id" => id, "attachment_id" => att_id}) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          attachments = message.attachments || %{}

          case find_attachment(attachments, att_id) do
            nil ->
              conn
              |> put_status(:not_found)
              |> json(%{error: "Attachment not found"})

            attachment ->
              case AttachmentStorage.generate_presigned_url(attachment) do
                {:ok, url} ->
                  conn
                  |> put_status(:ok)
                  |> json(%{
                    download_url: url,
                    filename: attachment_field(attachment, "filename", :filename),
                    content_type: attachment_field(attachment, "content_type", :content_type),
                    expires_in: 3600
                  })

                {:error, _reason} ->
                  conn
                  |> put_status(:internal_server_error)
                  |> json(%{error: "Failed to generate download URL"})
              end
          end

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  @doc """
  PUT /api/emails/:id/category
  Updates the category of an email.

  Params:
    - category: One of "inbox", "feed", "ledger", "stack"
  """
  def update_category(conn, %{"id" => id, "category" => category}) do
    user = conn.assigns[:current_user]

    valid_categories = ["inbox", "feed", "ledger", "stack"]

    if category not in valid_categories do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid category. Must be one of: #{Enum.join(valid_categories, ", ")}"})
    else
      with_message_id(conn, id, fn message_id ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            result =
              case category do
                "feed" -> Folders.move_to_digest(message)
                "ledger" -> Folders.move_to_ledger(message)
                _ -> move_to_category(message, category)
              end

            case result do
              {:ok, updated} ->
                conn
                |> put_status(:ok)
                |> json(%{
                  message: "Category updated successfully",
                  email: format_message(updated)
                })

              {:error, _reason} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Failed to update category"})
            end

          {:error, _reason} ->
            email_not_found(conn)

          nil ->
            email_not_found(conn)
        end
      end)
    end
  end

  @doc """
  PUT /api/emails/:id/reply-later
  Sets or clears reply-later reminder for an email.

  Params:
    - reminder_at: ISO 8601 datetime string (or null to clear)
  """
  def set_reply_later(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with_message_id(conn, id, fn message_id ->
      case Email.get_user_message(message_id, user.id) do
        {:ok, message} ->
          reminder_at = params["reminder_at"]

          result =
            if is_nil(reminder_at) || reminder_at == "" do
              # Clear reply later
              Folders.clear_reply_later(message)
            else
              # Set reply later
              case DateTime.from_iso8601(reminder_at) do
                {:ok, datetime, _offset} ->
                  Folders.reply_later_message(message, datetime)

                {:error, _} ->
                  {:error, :invalid_datetime}
              end
            end

          case result do
            {:ok, updated} ->
              conn
              |> put_status(:ok)
              |> json(%{
                message: "Reply later updated successfully",
                email: format_message(updated)
              })

            {:error, :invalid_datetime} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "Invalid datetime format. Use ISO 8601 format."})

            {:error, _reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to set reply later"})
          end

        {:error, _reason} ->
          email_not_found(conn)

        nil ->
          email_not_found(conn)
      end
    end)
  end

  # Private helpers

  # Generic category update for inbox/stack
  defp move_to_category(message, category) do
    message
    |> Message.changeset(%{category: category})
    |> Elektrine.Repo.update()
  end

  defp perform_bulk_action(message, "mark_read"), do: Email.mark_as_read(message)
  defp perform_bulk_action(message, "mark_unread"), do: Email.mark_as_unread(message)
  defp perform_bulk_action(message, "archive"), do: Email.archive_message(message)
  defp perform_bulk_action(message, "unarchive"), do: Email.unarchive_message(message)
  defp perform_bulk_action(message, "spam"), do: Email.mark_as_spam(message)
  defp perform_bulk_action(message, "not_spam"), do: Email.mark_as_not_spam(message)
  defp perform_bulk_action(message, "delete"), do: Email.delete_message(message)
  defp perform_bulk_action(_message, _action), do: {:error, :unknown_action}

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_positive_int(nil, default), do: default
  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_positive_int(value, default) when is_integer(value), do: default

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp parse_message_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_message_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_message_id(_), do: :error

  defp with_message_id(conn, id, fun) when is_function(fun, 1) do
    case parse_message_id(id) do
      {:ok, message_id} -> fun.(message_id)
      :error -> invalid_email_id(conn)
    end
  end

  defp invalid_email_id(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid email id"})
  end

  defp email_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Email not found"})
  end

  defp format_attachments(attachments) when is_map(attachments) do
    Enum.map(attachments, fn {key, att} ->
      attachment = if is_map(att), do: att, else: %{}

      %{
        id: attachment_field(attachment, "id", :id) || to_string(key),
        filename: attachment_field(attachment, "filename", :filename),
        content_type: attachment_field(attachment, "content_type", :content_type),
        size: attachment_field(attachment, "size", :size)
      }
    end)
  end

  defp format_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.map(fn {att, idx} ->
      attachment = if is_map(att), do: att, else: %{}

      %{
        id: attachment_field(attachment, "id", :id) || to_string(idx),
        filename: attachment_field(attachment, "filename", :filename),
        content_type: attachment_field(attachment, "content_type", :content_type),
        size: attachment_field(attachment, "size", :size)
      }
    end)
  end

  defp format_attachments(_), do: []

  defp find_attachment(attachments, att_id) when is_map(attachments) do
    target_id = to_string(att_id)

    Enum.find_value(attachments, fn {key, att} ->
      attachment = if is_map(att), do: att, else: nil

      if attachment do
        attachment_id = attachment_field(attachment, "id", :id) || to_string(key)

        if to_string(attachment_id) == target_id do
          attachment
        else
          nil
        end
      else
        nil
      end
    end)
  end

  defp find_attachment(attachments, att_id) when is_list(attachments) do
    target_id = to_string(att_id)

    # Try to find by id field first
    # Fallback to index-based lookup
    Enum.find(attachments, fn att ->
      id = attachment_field(att, "id", :id)
      to_string(id) == target_id
    end) ||
      case parse_int(att_id, nil) do
        idx when is_integer(idx) and idx >= 0 -> Enum.at(attachments, idx)
        _ -> nil
      end
  end

  defp find_attachment(_, _), do: nil

  defp attachment_field(attachment, string_key, atom_key) when is_map(attachment) do
    Map.get(attachment, string_key) || Map.get(attachment, atom_key)
  end

  defp attachment_field(_, _, _), do: nil

  # Private helper to format message for JSON response
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
      category: format_category(message.category),
      has_attachments: message.has_attachments,
      mailbox_id: message.mailbox_id,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  # Return raw category values for mobile API (mobile app handles display names)
  # Legacy category mapping
  defp format_category("paper_pile"), do: "feed"
  # Legacy category mapping
  defp format_category("important_stuff"), do: "ledger"
  # Legacy category mapping
  defp format_category("random_stuff"), do: "stack"
  defp format_category(nil), do: "inbox"
  defp format_category(category) when is_binary(category), do: category
  defp format_category(_), do: "inbox"
end
