defmodule ElektrineEmailWeb.EmailController do
  use ElektrineEmailWeb, :controller

  alias Elektrine.Email
  alias Elektrine.EmailAddresses
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator
  alias ElektrineWeb.Endpoint

  import ElektrineEmailWeb.Components.Email.Display

  @email_image_proxy_salt "email image proxy"
  @email_image_proxy_max_age_seconds 7 * 24 * 60 * 60
  @email_image_proxy_max_bytes 10 * 1024 * 1024

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

  def iframe_content(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SafeConvert.parse_id(id) do
      {:ok, message_id} ->
        case Email.get_user_message(message_id, user.id) do
          {:ok, message} ->
            content = iframe_email_content(conn, message)

            # Set security headers with relaxed CSP for email content
            # Emails often include external fonts, styles, and images from newsletters
            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> put_resp_header("content-security-policy", build_email_iframe_csp())
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

  def image_proxy(conn, %{"token" => token}) do
    user = conn.assigns.current_user

    with {:ok, %{"user_id" => user_id, "url" => url}} <-
           Phoenix.Token.verify(Endpoint, @email_image_proxy_salt, token,
             max_age: @email_image_proxy_max_age_seconds
           ),
         true <- user_id == user.id,
         :ok <- validate_email_image_url(url) do
      fetch_and_send_email_image(conn, url)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def image_proxy(conn, _params), do: send_resp(conn, 404, "Not found")

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

  defp normalize_iframe_email_content(content), do: content

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
      # Images: rewrite common HTML image references through the proxy, but keep
      # HTTPS as a fidelity fallback for CSS, picture/source, and poster assets.
      "img-src 'self' data: cid: https:",
      # Fonts: allow ANY HTTPS source (not just specific CDNs)
      # Common: fonts.googleapis.com, use.typekit.net, fonts.adobe.com, etc.
      "font-src 'self' data: https:",
      # Connect: block external connections
      "connect-src 'self'",
      # Media: allow common marketing-email media sources without scripts.
      "media-src 'self' data: cid: https:",
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

    {body_attributes, body_content} =
      case Regex.run(~r/<body\b[^>]*>(.*?)<\/body>/is, content) do
        [body_tag, body] -> {body_attributes(body_tag), body}
        _ -> {"", strip_document_shell(content)}
      end

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

  defp rewrite_email_html_assets(content, conn, message) do
    content
    |> rewrite_cid_image_urls(message)
    |> rewrite_remote_image_urls(conn)
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

  defp rewrite_remote_image_urls(content, conn) do
    content
    |> rewrite_remote_image_src_attributes(conn)
    |> rewrite_remote_image_srcset_attributes(conn)
    |> rewrite_remote_image_source_srcset_attributes(conn)
    |> rewrite_remote_media_poster_attributes(conn)
    |> rewrite_remote_background_attributes(conn)
    |> rewrite_remote_css_image_urls(conn)
  end

  defp rewrite_remote_image_src_attributes(content, conn) do
    Regex.replace(~r/(<img\b[^>]*\bsrc\s*=\s*["'])(https?:\/\/[^"']+)(["'][^>]*>)/i, content, fn
      _full, prefix, url, suffix ->
        if proxyable_email_image_url?(url) do
          prefix <> signed_email_image_proxy_path(conn, url) <> suffix
        else
          prefix <> url <> suffix
        end
    end)
  end

  defp rewrite_remote_image_srcset_attributes(content, conn) do
    Regex.replace(
      ~r/(<img\b[^>]*\bsrcset\s*=\s*["'])([^"']+)(["'][^>]*>)/i,
      content,
      fn _full, prefix, srcset, suffix ->
        prefix <> rewrite_srcset_urls(srcset, conn) <> suffix
      end
    )
  end

  defp rewrite_remote_image_source_srcset_attributes(content, conn) do
    Regex.replace(
      ~r/(<source\b[^>]*\bsrcset\s*=\s*["'])([^"']+)(["'][^>]*>)/i,
      content,
      fn _full, prefix, srcset, suffix ->
        prefix <> rewrite_srcset_urls(srcset, conn) <> suffix
      end
    )
  end

  defp rewrite_remote_media_poster_attributes(content, conn) do
    Regex.replace(
      ~r/(<video\b[^>]*\bposter\s*=\s*["'])(https?:\/\/[^"']+)(["'][^>]*>)/i,
      content,
      fn _full, prefix, url, suffix ->
        if proxyable_email_image_url?(url) do
          prefix <> signed_email_image_proxy_path(conn, url) <> suffix
        else
          prefix <> url <> suffix
        end
      end
    )
  end

  defp rewrite_remote_background_attributes(content, conn) do
    Regex.replace(
      ~r/(<[^>]*\bbackground\s*=\s*["'])(https?:\/\/[^"']+)(["'][^>]*>)/i,
      content,
      fn _full, prefix, url, suffix ->
        if proxyable_email_image_url?(url) do
          prefix <> signed_email_image_proxy_path(conn, url) <> suffix
        else
          prefix <> url <> suffix
        end
      end
    )
  end

  defp rewrite_remote_css_image_urls(content, conn) do
    {content, imports} = protect_import_statements(content, 0, [])
    content = do_rewrite_css_image_urls(content, conn)
    restore_import_statements(content, imports)
  end

  defp protect_import_statements(content, counter, acc) do
    content
    |> do_protect_import(
      ~r/@import\s+url\(\s*(['"]?)(https?:\/\/[^'")\s]+)\1\s*\)\s*;?/i,
      counter,
      acc
    )
  end

  defp do_protect_import(content, pattern, counter, acc) do
    case Regex.run(pattern, content) do
      [full_match | _] ->
        marker = "@IMPFIX#{counter}@"
        new_content = String.replace(content, full_match, marker, global: false)
        do_protect_import(new_content, pattern, counter + 1, [{marker, full_match} | acc])

      nil ->
        {content, acc}
    end
  end

  defp restore_import_statements(content, imports) do
    Enum.reduce(imports, content, fn {marker, original}, acc ->
      String.replace(acc, marker, original, global: false)
    end)
  end

  defp do_rewrite_css_image_urls(content, conn) do
    Regex.replace(~r/url\(\s*(['"]?)(https?:\/\/[^'")\s]+)\1\s*\)/i, content, fn
      _full, _quote, url ->
        if proxyable_email_image_url?(url) do
          "url(#{signed_email_image_proxy_path(conn, url)})"
        else
          "url(#{url})"
        end
    end)
  end

  defp rewrite_srcset_urls(srcset, conn) do
    Regex.replace(~r/https?:\/\/[^\s,]+/i, srcset, fn url ->
      if proxyable_email_image_url?(url) do
        signed_email_image_proxy_path(conn, url)
      else
        url
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

  defp signed_email_image_proxy_path(conn, url) do
    token =
      Phoenix.Token.sign(Endpoint, @email_image_proxy_salt, %{
        "user_id" => conn.assigns.current_user.id,
        "url" => url
      })

    ~p"/email/image_proxy?token=#{token}"
  end

  defp proxyable_email_image_url?(url) do
    with %URI{scheme: "https", host: host} <- URI.parse(url),
         true <- is_binary(host) and host != "" do
      true
    else
      _ -> false
    end
  end

  defp validate_email_image_url(url) when is_binary(url) do
    with :ok <- URLValidator.validate(url),
         %URI{scheme: "https", host: host} <- URI.parse(url),
         true <- is_binary(host) and host != "" do
      :ok
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_email_image_url(_url), do: {:error, :invalid_url}

  defp fetch_and_send_email_image(conn, url) do
    headers = [
      {"user-agent", "Elektrine/1.0 EmailImageProxy (+#{Endpoint.url()})"},
      {"accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"}
    ]

    request = Finch.build(:get, url, headers)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: 15_000,
           pool_timeout: 10_000,
           max_body_bytes: @email_image_proxy_max_bytes
         ) do
      {:ok, %Finch.Response{status: status, headers: response_headers, body: body}}
      when status in 200..299 ->
        content_type =
          response_header(response_headers, "content-type") || "application/octet-stream"

        if safe_email_image_content_type?(content_type) do
          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("cache-control", "private, max-age=86400")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_resp(200, body)
        else
          send_resp(conn, 415, "Unsupported media type")
        end

      {:error, :too_large} ->
        send_resp(conn, 413, "Image too large")

      _ ->
        send_resp(conn, 502, "Failed to fetch image")
    end
  end

  defp response_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp safe_email_image_content_type?(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> case do
      "image/jpeg" -> true
      "image/jpg" -> true
      "image/png" -> true
      "image/gif" -> true
      "image/webp" -> true
      "image/avif" -> true
      "image/apng" -> true
      _ -> false
    end
  end

  defp safe_email_image_content_type?(_content_type), do: false

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
