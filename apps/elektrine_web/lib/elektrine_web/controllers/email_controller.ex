defmodule ElektrineWeb.EmailController do
  use ElektrineWeb, :controller

  alias Elektrine.Email
  import ElektrineWeb.Components.Email.Display

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
            timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
            time_format = if user && user.time_format, do: user.time_format, else: "12"

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

  def iframe_content(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            # Sanitize the content (no need to decode - already decoded in DB)
            content =
              cond do
                message.html_body && String.trim(message.html_body) != "" ->
                  safe_sanitize_email_html(message.html_body)

                message.text_body && String.trim(message.text_body) != "" ->
                  escaped_text =
                    Phoenix.HTML.html_escape(message.text_body) |> Phoenix.HTML.safe_to_string()

                  "<pre style=\"font-family: monospace; font-size: 14px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; margin: 0; padding: 16px;\">#{escaped_text}</pre>"

                true ->
                  "<div style=\"display: flex; align-items: center; justify-content: center; height: 300px; color: #999; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;\"><p style=\"font-style: italic;\">This message has no content</p></div>"
              end

            # Set security headers with relaxed CSP for email content
            # Emails often include external fonts, styles, and images from newsletters
            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> put_resp_header("content-security-policy", build_email_iframe_csp())
            # Tell Cloudflare not to modify email iframe content
            |> put_resp_header("cf-edge-cache", "no-transform")
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

  # Build a relaxed CSP for email iframes
  # Emails from newsletters often include external fonts, tracking pixels, etc.
  # We need to allow these for proper email rendering while maintaining security
  defp build_email_iframe_csp do
    directives = [
      "default-src 'self'",
      # Scripts: block all scripts in emails for security
      "script-src 'none'",
      # Styles: allow ANY HTTPS source (newsletters use various CDNs)
      # Common: Google Fonts, Adobe Fonts, Font Awesome, Typekit, custom CDNs
      "style-src 'self' 'unsafe-inline' https:",
      # Images: allow all HTTPS sources (newsletters, tracking pixels)
      "img-src 'self' data: https:",
      # Fonts: allow ANY HTTPS source (not just specific CDNs)
      # Common: fonts.googleapis.com, use.typekit.net, fonts.adobe.com, etc.
      "font-src 'self' data: https:",
      # Connect: block external connections
      "connect-src 'self'",
      # Media: allow HTTPS (video embeds in emails)
      "media-src 'self' https:",
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

  defp build_iframe_html(content) do
    """
    <!DOCTYPE html>
    <html data-cf-beacon="false">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <!-- Disable Cloudflare's automatic script injection for email content -->
      <meta name="cf-dont-modify" content="true">
      <style>
        body {
          margin: 0;
          padding: 16px;
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          font-size: 14px;
          line-height: 1.5;
          color: #333;
          background: #ffffff;
          word-wrap: break-word;
          overflow-wrap: break-word;
        }
        img {
          max-width: 100%;
          height: auto;
        }
        a {
          color: #0066cc;
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
        table {
          max-width: 100%;
          border-collapse: collapse;
        }

        /* Only fix truly broken buttons (like Odysee with empty background-color) */
        a[style$="background-color:"],
        a[style$="background:"] {
          background-color: #1a73e8;
          border-radius: 4px;
          padding: 10px 20px;
        }

        /* Hide tracking pixels */
        img[width="1"][height="1"],
        img[style*="width: 1px"][style*="height: 1px"] {
          display: none !important;
        }

        /* Minimal mobile responsive styles */
        @media screen and (max-width: 600px) {
          body {
            padding: 8px !important;
          }

          /* Prevent images from overflowing */
          img {
            max-width: 100% !important;
            height: auto !important;
          }

          /* Allow tables to shrink on mobile */
          table {
            max-width: 100% !important;
          }
        }
      </style>
      <base target="_blank">
    </head>
    <body>
      #{content}
    </body>
    </html>
    """
  end

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
        message.message_id || "<#{message.id}@elektrine.com>"
      )
      |> Mail.Message.put_header("date", DateTime.shift_zone!(message.inserted_at, "Etc/UTC"))
      |> Mail.Message.put_header("from", message.from)
      |> Mail.Message.put_header("to", message.to)
      |> Mail.Message.put_header("subject", message.subject || "(no subject)")

    # Add optional headers
    mail_message =
      if message.cc && message.cc != "" do
        Mail.Message.put_header(mail_message, "cc", message.cc)
      else
        mail_message
      end

    mail_message =
      if message.bcc && message.bcc != "" do
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
