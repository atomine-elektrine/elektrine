defmodule ElektrineEmailWeb.EmailController do
  use ElektrineEmailWeb, :controller

  alias Elektrine.Email
  alias Elektrine.EmailAddresses

  import ElektrineEmailWeb.Components.Email.Display

  def delivery_status(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, message_id} <- SafeConvert.parse_id(id),
         {:ok, message} <- Email.get_user_message(message_id, user.id) do
      deliveries = Email.list_external_deliveries_for_message(message.id)

      json(conn, %{
        message_id: message.id,
        status: message.status,
        summary: Email.external_delivery_summary(message.id),
        deliveries:
          Enum.map(deliveries, fn delivery ->
            %{
              id: delivery.id,
              recipient: delivery.recipient,
              recipient_type: delivery.recipient_type,
              domain: delivery.domain,
              status: delivery.status,
              trace_id: delivery.trace_id,
              attempts: Enum.map(Email.list_external_delivery_attempts(delivery), &attempt_json/1)
            }
          end)
      })
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Message not found"})
    end
  end

  defp attempt_json(attempt) do
    %{
      attempt: attempt.attempt,
      status: attempt.status,
      provider: attempt.provider,
      provider_message_id: attempt.provider_message_id,
      response_code: attempt.response_code,
      error: attempt.error,
      attempted_at: attempt.attempted_at
    }
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            case Email.delete_message(message) do
              {:ok, _} ->
                conn
                |> put_flash(:info, "Message deleted successfully.")
                |> redirect(to: ~p"/email")

              {:error, _} ->
                conn
                |> put_flash(:error, "Failed to delete message.")
                |> redirect(to: ~p"/email")
            end

          {:error, :message_not_found} ->
            conn
            |> put_flash(:error, "Message not found.")
            |> redirect(to: ~p"/email")

          {:error, _} ->
            conn
            |> put_flash(:error, "You don't have permission to delete this message.")
            |> redirect(to: ~p"/email")
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid message ID.")
        |> redirect(to: ~p"/email")
    end
  end

  def print(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    mailbox = Email.get_user_mailbox(user.id)

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            # Mark as read if not already
            unless message.read do
              Email.mark_as_read(message)
            end

            # Set timezone and time_format from user preferences
            timezone = user.timezone || "Etc/UTC"
            time_format = user.time_format || "12"

            conn
            |> put_layout(false)
            |> render(:print,
              message: message,
              mailbox: mailbox,
              timezone: timezone,
              time_format: time_format
            )

          {:error, :message_not_found} ->
            conn
            |> put_flash(:error, "Message not found.")
            |> redirect(to: ~p"/email")

          {:error, _} ->
            conn
            |> put_flash(:error, "You don't have permission to view this message.")
            |> redirect(to: ~p"/email")
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid message ID.")
        |> redirect(to: ~p"/email")
    end
  end

  def download_eml(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            eml_content = generate_eml_content(message)
            filename = "email-#{message.id}.eml"

            conn
            |> put_resp_content_type("message/rfc822")
            |> put_resp_header("content-disposition", ~s[attachment; filename="#{filename}"])
            |> send_resp(200, eml_content)

          {:error, :message_not_found} ->
            conn
            |> put_flash(:error, "Message not found.")
            |> redirect(to: ~p"/email")

          {:error, _} ->
            conn
            |> put_flash(:error, "You don't have permission to download this message.")
            |> redirect(to: ~p"/email")
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid message ID.")
        |> redirect(to: ~p"/email")
    end
  end

  def original_html(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, message_id} <- SafeConvert.parse_id(id),
         {:ok, message} <- Email.get_user_message(message_id, user.id) do
      source = message.html_body || message.text_body || ""

      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, source)
    else
      {:error, :message_not_found} -> send_resp(conn, 404, "Message not found")
      {:error, _reason} -> send_resp(conn, 403, "Access denied")
    end
  end

  def iframe_content(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    # Remote images are blocked by default so tracking pixels don't fire on
    # open; the viewer opts in per message with ?images=1.
    allow_remote_images = params["images"] == "1"

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            content =
              conn
              |> iframe_email_content(message)
              |> maybe_block_remote_images(allow_remote_images)

            # Set security headers with relaxed CSP for email content
            # Emails often include external fonts, styles, and images from newsletters
            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> put_resp_header(
              "content-security-policy",
              build_email_iframe_csp(allow_remote_images)
            )
            |> put_resp_header("cache-control", "no-transform")
            |> put_resp_content_type("text/html")
            |> send_resp(200, build_iframe_html(content))

          {:error, :message_not_found} ->
            send_resp(conn, 404, "Message not found")

          {:error, _} ->
            send_resp(conn, 403, "Access denied")
        end

      {:error, _} ->
        send_resp(conn, 400, "Invalid message ID")
    end
  end

  defp iframe_email_content(conn, message) do
    if Email.Message.private_encrypted?(message) do
      "<div style=\"display: flex; align-items: center; justify-content: center; height: 300px; color: #666; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;\"><p style=\"max-width: 32rem; text-align: center;\">This message is protected by mailbox encryption. Unlock it in webmail to view the contents.</p></div>"
    else
      do_iframe_email_content(conn, message)
    end
  end

  defp do_iframe_email_content(conn, message) do
    sanitized_html =
      if Elektrine.Strings.present?(message.html_body) do
        safe_sanitize_email_html(message.html_body)
      end

    cond do
      Elektrine.Strings.present?(sanitized_html) ->
        sanitized_html
        |> normalize_iframe_email_content()
        |> rewrite_email_html_assets(conn, message)

      Elektrine.Strings.present?(message.text_body) ->
        plain_text_email_content(message.text_body)

      true ->
        "<div style=\"display: flex; align-items: center; justify-content: center; height: 300px; color: #999; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;\"><p style=\"font-style: italic; max-width: 32rem; text-align: center;\">This message does not contain a displayable text or HTML body.</p></div>"
    end
  end

  defp normalize_iframe_email_content(content) when is_binary(content) do
    if html_fragment?(content) do
      content
    else
      plain_text_email_content(content)
    end
  end

  defp html_fragment?(content) when is_binary(content) do
    Regex.match?(
      ~r/<\/?(?:html|head|body|table|tbody|tr|td|div|p|span|br|a|img|style|section|article|h[1-6])\b/i,
      content
    )
  end

  defp plain_text_email_content(text) do
    content =
      text
      |> clean_plain_text_body()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> linkify_plain_text()

    "<pre style=\"font-family: monospace; font-size: 14px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; margin: 0; padding: 16px;\">#{content}</pre>"
  end

  defp linkify_plain_text(escaped_text) do
    escaped_text
    |> String.replace(~r/(https?:\/\/[^\s<]+)/i, fn url ->
      ~s(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{url}</a>)
    end)
    |> String.replace(~r/\b([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})\b/i, fn email ->
      ~s(<a href="mailto:#{email}">#{email}</a>)
    end)
  end

  # Build the CSP for email iframes. Scripts are always blocked.
  #
  # With remote images allowed, styles/images/fonts/media may load from any
  # HTTPS source since newsletters use assorted CDNs. With them blocked
  # (the default), the CSP is the hard enforcement that keeps tracking
  # pixels, CSS background images, and remote fonts from phoning home.
  defp build_email_iframe_csp(allow_remote) do
    remote = if allow_remote, do: " https:", else: ""

    directives = [
      "default-src 'self'",
      # Scripts: block all scripts in emails for security
      "script-src 'none'",
      "style-src 'self' 'unsafe-inline'#{remote}",
      "img-src 'self' data: cid:#{remote}",
      "font-src 'self' data:#{remote}",
      # Connect: block external connections
      "connect-src 'self'",
      "media-src 'self' data: cid:#{remote}",
      # Frames: block nested iframes
      "frame-src 'none'",
      # Objects: block all
      "object-src 'none'",
      # Base URI: restrict to self
      "base-uri 'self'",
      # Forms: block form submissions
      "form-action 'none'"
    ]

    Enum.join(directives, "; ")
  end

  # 1x1 transparent GIF so blocked remote images don't render as broken icons.
  # The tightened CSP is the actual enforcement; this is cosmetic.
  @remote_image_placeholder "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

  defp maybe_block_remote_images(content, true), do: content
  defp maybe_block_remote_images(content, false) when not is_binary(content), do: content

  defp maybe_block_remote_images(content, false) do
    content
    |> then(
      &Regex.replace(
        ~r/(<img\b[^>]*?\bsrc\s*=\s*["'])\s*https?:[^"']*(["'])/i,
        &1,
        "\\1#{@remote_image_placeholder}\\2"
      )
    )
    |> then(
      &Regex.replace(~r/(<(?:img|source)\b[^>]*?)\bsrcset\s*=\s*["'][^"']*["']/i, &1, "\\1")
    )
  end

  defp build_iframe_html(content) do
    {head_content, body_attributes, body_content} = split_email_document_content(content)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <style>
        html,
        body {
          margin: 0;
          padding: 0;
          background: #ffffff;
        }
        img {
          border: 0;
        }
      </style>
      #{head_content}
      <base target="_blank">
    </head>
    <body#{body_attributes}>
      #{body_content}
    </body>
    </html>
    """
  end

  defp split_email_document_content(content) when is_binary(content) do
    extracted_head_content =
      Regex.scan(~r/<style\b[^>]*>.*?<\/style>|<link\b[^>]*>/is, content)
      |> Enum.map_join("\n", fn [match | _] -> match end)

    # Keep content outside any embedded <body> shell: replies quote full HTML
    # documents inline, so extracting only the <body> interior would drop the
    # reply text written above the quote.
    body_attributes =
      case Regex.run(~r/<body\b[^>]*>/is, content) do
        [body_tag] -> body_attributes(body_tag)
        _ -> ""
      end

    body_content = strip_document_shell(content)

    body_content = remove_extracted_head_content(body_content)

    {css_preamble, body_content} = split_leading_css_preamble(body_content)

    head_content =
      [extracted_head_content, css_preamble_style(css_preamble)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    {head_content, body_attributes, body_content}
  end

  defp split_email_document_content(content), do: {"", "", content}

  defp body_attributes(body_tag) do
    case Regex.run(~r/<body\b([^>]*)>/is, body_tag) do
      [_, attributes] -> normalize_body_attributes(attributes)
      _ -> ""
    end
  end

  defp normalize_body_attributes(attributes) do
    attributes = String.trim(attributes || "")

    if attributes == "" do
      ""
    else
      " " <> attributes
    end
  end

  defp strip_document_shell(content) do
    content
    |> String.replace(~r/<!doctype[^>]*>/i, "")
    |> String.replace(~r/<\/?html\b[^>]*>/i, "")
    |> String.replace(~r/<head\b[^>]*>.*?<\/head>/is, "")
    |> String.replace(~r/<\/?body\b[^>]*>/i, "")
  end

  defp remove_extracted_head_content(content) do
    content
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<link\b[^>]*>/is, "")
  end

  defp split_leading_css_preamble(content) do
    case Regex.run(~r/\A([\s\S]*?)(<[a-zA-Z][\s\S]*)\z/, content) do
      [_, prefix, html] ->
        if css_preamble?(prefix) do
          {String.trim(prefix), html}
        else
          {"", content}
        end

      _ ->
        {"", content}
    end
  end

  defp css_preamble?(prefix) do
    prefix = String.trim(prefix || "")

    prefix != "" and
      (String.contains?(prefix, ["@import", "@media"]) or
         (String.contains?(prefix, "{") and String.contains?(prefix, "}")))
  end

  defp css_preamble_style(""), do: nil
  defp css_preamble_style(css), do: "<style>#{css}</style>"

  defp rewrite_email_html_assets(content, _conn, message) do
    rewrite_cid_image_urls(content, message)
  end

  defp rewrite_cid_image_urls(content, message) do
    Regex.replace(~r/(<img\b[^>]*\bsrc\s*=\s*["'])cid:([^"']+)(["'][^>]*>)/i, content, fn
      _full, prefix, cid, suffix ->
        case cid_attachment_path(message, cid) do
          nil -> prefix <> "cid:" <> cid <> suffix
          path -> prefix <> path <> suffix
        end
    end)
  end

  defp cid_attachment_path(message, cid) do
    cid = normalize_content_id(cid)

    message.attachments
    |> normalize_attachments_map()
    |> Enum.find_value(fn {attachment_id, attachment} ->
      if normalize_content_id(attachment["content_id"] || attachment[:content_id]) == cid do
        ~p"/email/message/#{message.id}/attachment/#{attachment_id}/download"
      end
    end)
  end

  defp normalize_content_id(value) when is_binary(value) do
    value
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.downcase()
  end

  defp normalize_content_id(_value), do: nil

  defp normalize_attachments_map(attachments) when is_map(attachments), do: attachments
  defp normalize_attachments_map(_attachments), do: %{}

  defp generate_eml_content(message) do
    # Use Mail library's builder functions to create the message properly
    has_both_parts = message.html_body && message.text_body

    # Build the appropriate message type
    mail_message =
      if has_both_parts do
        # Multipart for both text and HTML
        Mail.build_multipart()
      else
        # Single part
        Mail.build()
      end

    # Add headers
    mail_message =
      mail_message
      |> Mail.Message.put_header(
        "message-id",
        message.message_id || EmailAddresses.message_id(message.id)
      )
      |> Mail.Message.put_header("date", DateTime.shift_zone!(message.inserted_at, "Etc/UTC"))
      |> Mail.Message.put_header("from", message.from)
      |> Mail.Message.put_header("to", message.to)
      |> Mail.Message.put_header("subject", message.subject || "(no subject)")

    # Add optional headers
    mail_message =
      if Elektrine.Strings.present?(message.cc) do
        Mail.Message.put_header(mail_message, "cc", message.cc)
      else
        mail_message
      end

    mail_message =
      if Elektrine.Strings.present?(message.bcc) do
        Mail.Message.put_header(mail_message, "bcc", message.bcc)
      else
        mail_message
      end

    # Add body parts
    mail_message =
      cond do
        message.html_body && message.text_body ->
          # Both text and HTML - add both parts to multipart message
          mail_message
          |> Mail.put_text(message.text_body)
          |> Mail.put_html(message.html_body)

        message.html_body ->
          # HTML only
          Mail.put_html(mail_message, message.html_body)

        message.text_body ->
          # Text only
          Mail.put_text(mail_message, message.text_body)

        true ->
          # No body
          Mail.put_text(mail_message, "")
      end

    # Render to RFC2822 format (EML)
    Mail.Renderers.RFC2822.render(mail_message)
  end

  def download_export(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SafeConvert.parse_id(id) do
      {:ok, export_id} ->
        case Email.get_export(export_id, user.id) do
          nil ->
            conn
            |> put_flash(:error, "Export not found.")
            |> redirect(to: ~p"/email/settings?tab=export")

          export ->
            case Email.get_download_path(export) do
              {:ok, file_path} ->
                filename = Path.basename(file_path)

                conn
                |> put_resp_content_type(get_export_content_type(export.format))
                |> put_resp_header(
                  "content-disposition",
                  "attachment; filename=\"#{filename}\""
                )
                |> send_file(200, file_path)

              {:error, :file_not_found} ->
                conn
                |> put_flash(:error, "Export file not found.")
                |> redirect(to: ~p"/email/settings?tab=export")

              {:error, :not_ready} ->
                conn
                |> put_flash(:error, "Export is not ready for download.")
                |> redirect(to: ~p"/email/settings?tab=export")
            end
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid export ID.")
        |> redirect(to: ~p"/email/settings?tab=export")
    end
  end

  defp get_export_content_type("mbox"), do: "application/mbox"
  defp get_export_content_type("zip"), do: "application/zip"
  defp get_export_content_type("eml"), do: "application/zip"
  defp get_export_content_type(_), do: "application/octet-stream"
end
