defmodule ElektrineWeb.Admin.MessagesController do
  @moduledoc """
  Controller for admin message viewing and management.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Email, Repo}
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
    show_domain_stats = truthy_param?(Map.get(params, "show_domains"))
    page = SafeConvert.parse_page(params)
    per_page = 50

    {messages, total_count} =
      if search_query != "" do
        search_messages_paginated(search_query, page, per_page)
      else
        get_recent_messages_paginated(page, per_page)
      end

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)
    {received_messages, sent_messages} = Enum.split_with(messages, &(&1.status == "received"))

    # Domain stats query scans outbound recipient fields across the message table.
    # Keep it opt-in so the default messages page stays responsive.
    recipient_domains =
      if show_domain_stats do
        Elektrine.Email.get_unique_recipient_domains_paginated(1, 20)
      else
        {[], 0}
      end

    render(conn, :messages,
      messages: messages,
      received_messages: received_messages,
      sent_messages: sent_messages,
      search_query: search_query,
      show_domain_stats: show_domain_stats,
      page_results_count: length(messages),
      recipient_domains: recipient_domains,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def view(conn, %{"id" => message_id}) do
    message = Email.get_message_admin(message_id)

    if message do
      # Get the user who owns this message
      mailbox = Email.get_mailbox_admin(message.mailbox_id)
      user = if mailbox, do: Accounts.get_user!(mailbox.user_id), else: nil

      # Decrypt message for admin viewing
      decrypted_message =
        if mailbox && mailbox.user_id do
          Elektrine.Email.Message.decrypt_content(message, mailbox.user_id)
        else
          message
        end

      render(conn, :view_message, message: decrypted_message, user: user)
    else
      conn
      |> put_flash(:error, "Message not found")
      |> redirect(to: ~p"/pripyat/messages")
    end
  end

  def user_messages(conn, %{"id" => user_id} = params) do
    case SafeConvert.parse_id(user_id) do
      {:ok, user_id} ->
        user = Accounts.get_user!(user_id)
        page = SafeConvert.parse_page(params)
        per_page = 20

        {messages, total_count} = get_user_messages_paginated(user_id, page, per_page)
        total_pages = ceil(total_count / per_page)
        page_range = pagination_range(page, total_pages)

        render(conn, :user_messages,
          user: user,
          messages: messages,
          current_page: page,
          total_pages: total_pages,
          total_count: total_count,
          page_range: page_range
        )

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid user ID")
        |> redirect(to: ~p"/pripyat/messages")
    end
  end

  def view_user_message(conn, %{"user_id" => user_id, "id" => message_id}) do
    with {:ok, user_id_int} <- SafeConvert.parse_id(user_id),
         user <- Accounts.get_user!(user_id_int),
         message <- Email.get_message_admin(message_id),
         true <- !is_nil(message),
         mailbox <- Email.get_mailbox_admin(message.mailbox_id),
         true <- mailbox && mailbox.user_id == user_id_int do
      # Decrypt message for admin viewing
      decrypted_message = Elektrine.Email.Message.decrypt_content(message, mailbox.user_id)

      render(conn, :view_user_message, user: user, message: decrypted_message)
    else
      _ ->
        conn
        |> put_flash(:error, "Message not found or invalid user ID")
        |> redirect(to: ~p"/pripyat/messages")
    end
  end

  def view_raw(conn, %{"id" => message_id}) do
    message = Email.get_message_admin(message_id)

    if message do
      # Get the user who owns this message
      mailbox = Email.get_mailbox_admin(message.mailbox_id)
      _user = if mailbox, do: Accounts.get_user!(mailbox.user_id), else: nil

      # Decrypt message for admin viewing
      decrypted_message =
        if mailbox && mailbox.user_id do
          Elektrine.Email.Message.decrypt_content(message, mailbox.user_id)
        else
          message
        end

      # Get raw email content from metadata
      raw_content = get_raw_email_content(decrypted_message)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, raw_content)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Message not found")
    end
  end

  def view_user_message_raw(conn, %{"user_id" => user_id, "id" => message_id}) do
    with {:ok, user_id_int} <- SafeConvert.parse_id(user_id),
         _user <- Accounts.get_user!(user_id_int),
         message <- Email.get_message_admin(message_id),
         true <- !is_nil(message),
         mailbox <- Email.get_mailbox_admin(message.mailbox_id),
         true <- mailbox && mailbox.user_id == user_id_int do
      # Decrypt message for admin viewing
      decrypted_message = Elektrine.Email.Message.decrypt_content(message, mailbox.user_id)

      # Get raw email content from metadata
      raw_content = get_raw_email_content(decrypted_message)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, raw_content)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Message not found or invalid user ID")
    end
  end

  def iframe(conn, %{"id" => message_id}) do
    message = Email.get_message_admin(message_id)

    case message do
      nil ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(404, "Message not found")

      message ->
        # Decrypt message for admin viewing
        mailbox = Email.get_mailbox_admin(message.mailbox_id)

        decrypted_message =
          if mailbox && mailbox.user_id do
            Elektrine.Email.Message.decrypt_content(message, mailbox.user_id)
          else
            message
          end

        html_content =
          if decrypted_message.html_body && String.trim(decrypted_message.html_body) != "" do
            # Use proper HTML sanitization to prevent XSS
            # Wrap in try/rescue to handle malformed HTML that can crash mochiweb_html parser
            try do
              HtmlSanitizeEx.Scrubber.scrub(
                decrypted_message.html_body,
                ElektrineWeb.EmailScrubber
              )
            rescue
              _ ->
                # Fall back to escaped plain text if HTML parsing fails
                # html_escape returns {:safe, string} tuple, so we need to extract the string
                text_content = decrypted_message.text_body || decrypted_message.html_body || ""

                escaped_text =
                  text_content
                  |> Phoenix.HTML.html_escape()
                  |> Phoenix.HTML.safe_to_string()

                "<pre style=\"white-space: pre-wrap; font-family: monospace;\">#{escaped_text}</pre>"
            end
          else
            "<p>No HTML content available</p>"
          end

        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("x-frame-options", "SAMEORIGIN")
        |> put_resp_header(
          "content-security-policy",
          "default-src 'self' 'unsafe-inline'; img-src 'self' data: https:; style-src 'self' 'unsafe-inline';"
        )
        |> send_resp(200, html_content)
    end
  end

  # Private helper functions

  defp get_recent_messages_paginated(page, per_page) do
    offset = (page - 1) * per_page

    # Select lightweight fields for list views; full/decrypted content is only needed in view actions.
    query =
      from(m in Email.Message,
        left_join: mb in Email.Mailbox,
        on: m.mailbox_id == mb.id,
        left_join: u in Accounts.User,
        on: mb.user_id == u.id,
        order_by: [desc: m.inserted_at]
      )
      |> select_message_summary()

    total_count = Repo.aggregate(Email.Message, :count, :id)

    messages =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {messages, total_count}
  end

  defp search_messages_paginated(search_query, page, per_page) do
    offset = (page - 1) * per_page
    search_term = "%#{search_query}%"

    # Search over indexed/header fields only and keep payload lightweight for fast list rendering.
    query =
      from(m in Email.Message,
        left_join: mb in Email.Mailbox,
        on: m.mailbox_id == mb.id,
        left_join: u in Accounts.User,
        on: mb.user_id == u.id,
        where:
          ilike(m.subject, ^search_term) or ilike(m.from, ^search_term) or
            ilike(fragment("COALESCE(?, '')", u.username), ^search_term),
        order_by: [desc: m.inserted_at]
      )
      |> select_message_summary()

    total_count =
      from(m in Email.Message,
        left_join: mb in Email.Mailbox,
        on: m.mailbox_id == mb.id,
        left_join: u in Accounts.User,
        on: mb.user_id == u.id,
        where:
          ilike(m.subject, ^search_term) or ilike(m.from, ^search_term) or
            ilike(fragment("COALESCE(?, '')", u.username), ^search_term)
      )
      |> Repo.aggregate(:count, :id)

    messages =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {messages, total_count}
  end

  defp get_user_messages_paginated(user_id, page, per_page) do
    offset = (page - 1) * per_page

    # User message list does not need body decryption; keep query to list columns.
    query =
      from(m in Email.Message,
        join: mb in Email.Mailbox,
        on: m.mailbox_id == mb.id,
        where: mb.user_id == ^user_id,
        order_by: [desc: m.inserted_at],
        select: %{
          id: m.id,
          subject: m.subject,
          from: m.from,
          to: m.to,
          status: m.status,
          read: m.read,
          spam: m.spam,
          category: m.category,
          inserted_at: m.inserted_at
        }
      )

    total_count =
      from(m in Email.Message,
        join: mb in Email.Mailbox,
        on: m.mailbox_id == mb.id,
        where: mb.user_id == ^user_id
      )
      |> Repo.aggregate(:count, :id)

    messages =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {messages, total_count}
  end

  defp select_message_summary(query) do
    from([m, mb, u] in query,
      select: %{
        id: m.id,
        subject: m.subject,
        from: m.from,
        to: m.to,
        status: m.status,
        inserted_at: m.inserted_at,
        mailbox: %{
          email: mb.email,
          user: %{username: u.username}
        }
      }
    )
  end

  defp truthy_param?(value) when value in [true, 1, "1", "true", "on", "yes"], do: true
  defp truthy_param?(_), do: false

  defp get_raw_email_content(message) do
    if message.metadata && Map.has_key?(message.metadata, "raw_email") do
      # Check if raw email content is stored in metadata
      message.metadata["raw_email"]
    else
      # Fall back to reconstructing from available fields
      construct_raw_email_fallback(message)
    end
  end

  defp construct_raw_email_fallback(message) do
    # Get mailbox and user information
    mailbox = if message.mailbox_id, do: Email.get_mailbox_admin(message.mailbox_id), else: nil
    user = if mailbox && mailbox.user_id, do: Accounts.get_user!(mailbox.user_id), else: nil

    """
    ===============================================================================
    DATABASE RECORD INFORMATION
    ===============================================================================

    MESSAGE DATABASE FIELDS:
    ------------------------
    ID: #{message.id}
    Message-ID: #{message.message_id || "N/A"}
    From: #{message.from || "N/A"}
    To: #{message.to || "N/A"}
    CC: #{message.cc || "(None)"}
    BCC: #{message.bcc || "(None)"}
    Subject: #{message.subject || "(No Subject)"}
    Status: #{message.status || "N/A"}
    Category: #{message.category || "N/A"}

    FLAGS & STATES:
    ---------------
    Read: #{message.read}
    Spam: #{message.spam}
    Archived: #{message.archived}
    Has Attachments: #{message.has_attachments || false}
    Reply Later At: #{message.reply_later_at || "(Not set)"}

    TIMESTAMPS:
    -----------
    Inserted At: #{message.inserted_at}
    Updated At: #{message.updated_at}

    MAILBOX ASSOCIATION:
    --------------------
    Mailbox ID: #{message.mailbox_id || "N/A"}
    #{if mailbox do
      """
      Mailbox Email: #{mailbox.email}
      Mailbox Forward To: #{mailbox.forward_to || "(None)"}
      Mailbox Forward Enabled: #{mailbox.forward_enabled || false}
      Mailbox Created: #{mailbox.inserted_at}
      Mailbox Updated: #{mailbox.updated_at}
      """
    else
      "Mailbox: (Not found or deleted)"
    end}

    USER ASSOCIATION:
    -----------------
    User ID: #{(mailbox && mailbox.user_id) || "N/A"}
    #{if user do
      """
      Username: #{user.username}
      Display Name: #{user.display_name || "(Not set)"}
      Is Admin: #{user.is_admin}
      Banned: #{user.banned}
      Two Factor Enabled: #{user.two_factor_enabled}
      User Created: #{user.inserted_at}
      Last Login: #{user.last_login_at || "(Never)"}
      Last Login IP: #{user.last_login_ip || "(Unknown)"}
      Login Count: #{user.login_count}
      Recovery Email: #{user.recovery_email || "(Not set)"}
      Registration IP: #{user.registration_ip || "(Unknown)"}
      """
    else
      "User: (Not found, deleted, or mailbox is orphaned)"
    end}

    ===============================================================================
    EMAIL CONTENT
    ===============================================================================

    --- TEXT BODY ---
    #{message.text_body || "(No text content)"}

    --- HTML BODY ---
    #{message.html_body || "(No HTML content)"}

    ===============================================================================
    METADATA & ATTACHMENTS
    ===============================================================================

    --- FULL METADATA JSON ---
    #{if message.metadata, do: Jason.encode!(message.metadata, pretty: true), else: "(No metadata)"}

    --- ATTACHMENTS INFO ---
    #{format_attachments_info(message.attachments)}

    ===============================================================================
    RAW ELIXIR STRUCT INSPECT
    ===============================================================================
    #{inspect(message, pretty: true, limit: :infinity)}

    ===============================================================================
    END OF RAW EMAIL DATA
    ===============================================================================
    """
  end

  defp format_attachments_info(attachments)
       when is_map(attachments) and map_size(attachments) > 0 do
    attachments
    |> Enum.map(fn {key, attachment} ->
      filename = Map.get(attachment, "filename", "unknown")
      content_type = Map.get(attachment, "content_type", "unknown")
      size = Map.get(attachment, "size", "unknown")
      encoding = Map.get(attachment, "encoding", "unknown")
      disposition = Map.get(attachment, "disposition", "unknown")
      content_id = Map.get(attachment, "content_id", "(none)")
      hash = Map.get(attachment, "hash", "(none)")

      data_preview =
        case Map.get(attachment, "data") do
          nil ->
            "(no data)"

          "" ->
            "(empty)"

          data when is_binary(data) ->
            preview = String.slice(data, 0, 100)

            if String.length(data) > 100 do
              "#{preview}... (#{String.length(data)} chars total)"
            else
              preview
            end

          _ ->
            "(non-string data)"
        end

      """
      #{key}:
        Filename: #{filename}
        Content-Type: #{content_type}
        Size: #{size} bytes
        Encoding: #{encoding}
        Disposition: #{disposition}
        Content-ID: #{content_id}
        Hash: #{hash}
        Data Preview: #{data_preview}
      """
    end)
    |> Enum.map_join("\n", & &1)
  end

  defp format_attachments_info(attachments)
       when is_list(attachments) and attachments != [] do
    """
    Attachments stored as list: #{length(attachments)} items
    Raw data: #{inspect(attachments, pretty: true)}
    """
  end

  defp format_attachments_info(nil), do: "(No attachments - nil)"
  defp format_attachments_info(%{}), do: "(No attachments - empty map)"
  defp format_attachments_info([]), do: "(No attachments - empty list)"
  defp format_attachments_info(other), do: "(Attachments in unknown format: #{inspect(other)})"

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
