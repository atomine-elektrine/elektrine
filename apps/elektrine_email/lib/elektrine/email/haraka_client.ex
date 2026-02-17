defmodule Elektrine.Email.HarakaClient do
  @moduledoc """
  HTTP API client for Haraka server.

  Supports:
  - Sending emails via Haraka HTTP API
  - RFC 2047 MIME encoding for non-ASCII headers
  """

  require Logger

  @default_base_url "https://haraka.elektrine.com"
  @api_path "/api/v1/send"

  def forward_email(original_email_data, forward_to_email, from_address) do
    # Get original sender info (support both atom and string keys)
    original_from =
      Map.get(original_email_data, "from") || Map.get(original_email_data, :from) ||
        "unknown@sender.com"

    original_subject =
      Map.get(original_email_data, "subject") || Map.get(original_email_data, :subject) || ""

    # Extract just the email address from original_from for API fields
    # The API may not accept quoted display name format like "Name" <email@domain.com>
    {original_from_email, _name} = extract_email_and_name(original_from)

    # Update subject to indicate it's forwarded
    forwarded_subject =
      if String.starts_with?(original_subject, "Fwd: ") do
        original_subject
      else
        "Fwd: #{original_subject}"
      end

    # Convert attachments to format needed for sending
    attachments_for_sending =
      Map.get(original_email_data, "attachments") || Map.get(original_email_data, :attachments) ||
        %{}

    html_body =
      Map.get(original_email_data, "html_body") || Map.get(original_email_data, :html_body)

    text_body =
      Map.get(original_email_data, "text_body") || Map.get(original_email_data, :text_body)

    email_params = %{
      from: from_address,
      to: forward_to_email,
      # Set Reply-To to original sender email only
      reply_to: original_from_email,
      # Set Sender header to original sender email only
      sender: original_from_email,
      subject: forwarded_subject,
      html_body: html_body,
      text_body: text_body,
      attachments: attachments_for_sending,
      # Add custom headers to preserve original sender info (full format with name)
      headers: %{
        "X-Original-From" => original_from,
        "X-Forwarded-By" => from_address,
        "X-Forwarded-Date" => DateTime.utc_now() |> DateTime.to_string()
      }
    }

    send_email(email_params)
  end

  def send_email(params) do
    from_address = params[:from] || ""

    case get_api_config_for_domain(from_address) do
      {:error, reason} ->
        Logger.error("Cannot send email via Haraka HTTP API: #{reason}")
        {:error, reason}

      {:ok, {api_key, base_url}} ->
        params_with_origin = add_internal_origin_headers(params)

        headers = [
          {"Content-Type", "application/json"},
          {"X-API-Key", api_key},
          {"User-Agent", "Elektrine-Haraka-Client/1.0"}
        ]

        body = build_api_body(params_with_origin)

        request = Finch.build(:post, "#{base_url}#{@api_path}", headers, body)

        case Finch.request(request, Elektrine.Finch, receive_timeout: 60_000) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            case Jason.decode(response_body) do
              {:ok, %{"success" => true, "message_id" => message_id}} ->
                {:ok, %{id: message_id, message_id: message_id}}

              {:ok, %{"success" => false, "error" => error}} ->
                Logger.error("Haraka HTTP API error: #{inspect(error)}")
                {:error, error}

              {:ok, response} ->
                Logger.error("Unexpected Haraka HTTP API response: #{inspect(response)}")
                {:error, "Unexpected response format"}

              {:error, decode_error} ->
                Logger.error(
                  "Failed to decode Haraka HTTP API response: #{inspect(decode_error)}"
                )

                {:error, "Invalid JSON response"}
            end

          {:ok, %Finch.Response{status: status_code, body: response_body}} ->
            # Try to parse the error response for more details
            error_detail =
              case Jason.decode(response_body) do
                {:ok, %{"error" => error}} -> error
                {:ok, %{"message" => msg}} -> msg
                _ -> response_body
              end

            Logger.error("Haraka HTTP API returned status #{status_code}: #{error_detail}")
            {:error, "Haraka HTTP API returned status #{status_code}: #{error_detail}"}

          {:error, reason} ->
            Logger.error("HTTP request to Haraka failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp get_api_config_for_domain(_from_address) do
    base_url = System.get_env("HARAKA_BASE_URL") || @default_base_url

    case System.get_env("HARAKA_OUTBOUND_API_KEY") || System.get_env("HARAKA_API_KEY") do
      nil ->
        {:error, "HARAKA_OUTBOUND_API_KEY (or HARAKA_API_KEY fallback) is not set"}

      "" ->
        {:error, "HARAKA_OUTBOUND_API_KEY (or HARAKA_API_KEY fallback) is empty"}

      api_key ->
        {:ok, {api_key, base_url}}
    end
  end

  defp build_api_body(params) do
    # If raw email data is provided, use that directly (preserves attachments and MIME structure)
    if params[:raw_email] do
      # Base64 encode raw email to safely transmit binary data in JSON
      body = %{
        "raw_base64" => Base.encode64(params[:raw_email]),
        "from" => params[:from],
        "to" => normalize_recipients_for_api(params[:to])
      }

      Jason.encode!(body)
    else
      # For Haraka, format From field with RFC 2047 encoding for non-ASCII display names
      from_field =
        case extract_email_and_name(params[:from]) do
          {email, nil} ->
            # No display name, use email only
            email

          {email, name} when name != "" ->
            # RFC 2047 encode the display name if it contains non-ASCII
            encoded_name = encode_mime_header(name)
            "#{encoded_name} <#{email}>"

          {email, _} ->
            # Fallback to email only
            email
        end

      # Build the JSON body for Haraka HTTP API
      # CRITICAL: Sanitize ALL fields to ensure valid UTF-8 for JSON encoding
      # Jason.encode! will fail on invalid UTF-8 bytes
      # Subject gets RFC 2047 MIME encoding for non-ASCII characters (like Chinese)
      raw_subject = ensure_field_utf8_safe(params[:subject] || params["subject"] || "")
      subject_safe = encode_mime_header(raw_subject)

      from_safe = ensure_field_utf8_safe(from_field)
      to_safe = ensure_field_utf8_safe(normalize_recipients_for_api(params[:to]))

      body = %{
        "from" => from_safe,
        "to" => to_safe,
        "subject" => subject_safe
      }

      # Add Reply-To if present
      body =
        if params[:reply_to] && params[:reply_to] != "" do
          Map.put(body, "reply_to", ensure_field_utf8_safe(params[:reply_to]))
        else
          body
        end

      # Add CC if present
      body =
        if params[:cc] && params[:cc] != "" do
          Map.put(body, "cc", ensure_field_utf8_safe(normalize_recipients_for_api(params[:cc])))
        else
          body
        end

      # Add BCC if present
      body =
        if params[:bcc] && params[:bcc] != "" do
          Map.put(body, "bcc", ensure_field_utf8_safe(normalize_recipients_for_api(params[:bcc])))
        else
          body
        end

      # Add body content - send both HTML and text when both are available
      has_html = params[:html_body] && String.trim(params[:html_body]) != ""
      has_text = params[:text_body] && String.trim(params[:text_body]) != ""

      body =
        cond do
          has_html && has_text ->
            # Send both HTML and text for proper multipart/alternative MIME
            body
            |> Map.put("html_body", ensure_field_utf8_safe(params[:html_body]))
            |> Map.put("text_body", ensure_field_utf8_safe(params[:text_body]))

          has_html ->
            # HTML only
            Map.put(body, "html_body", ensure_field_utf8_safe(params[:html_body]))

          has_text ->
            # Plain text only
            Map.put(body, "text_body", ensure_field_utf8_safe(params[:text_body]))

          params[:text_body] ->
            # Even if text_body is empty string, include it
            Map.put(body, "text_body", ensure_field_utf8_safe(params[:text_body]))

          true ->
            # Fallback - add empty text body
            Map.put(body, "text_body", "")
        end

      # Add custom headers (for threading, forwarding info, etc.)
      # Don't set Content-Type - let Haraka handle it automatically based on html_body/text_body
      headers = %{
        "Content-Transfer-Encoding" => "8bit"
      }

      # Add In-Reply-To header if present
      headers =
        if params[:in_reply_to] do
          Map.put(headers, "In-Reply-To", params[:in_reply_to])
        else
          headers
        end

      # Add custom forwarding headers if present
      headers =
        if params[:headers] && is_map(params[:headers]) do
          # Sanitize all header values
          sanitized_custom_headers =
            params[:headers]
            |> Enum.map(fn {k, v} -> {k, ensure_field_utf8_safe(v)} end)
            |> Map.new()

          Map.merge(headers, sanitized_custom_headers)
        else
          headers
        end

      # Always add headers to body (we now have default charset headers)
      body = Map.put(body, "headers", headers)

      # Add sender field if present (for forwarding)
      body =
        if params[:sender] && params[:sender] != "" do
          Map.put(body, "sender", ensure_field_utf8_safe(params[:sender]))
        else
          body
        end

      # Add attachments if present
      body =
        if params[:attachments] && is_map(params[:attachments]) &&
             map_size(params[:attachments]) > 0 do
          # Convert attachments map to list format for API
          attachments_list =
            params[:attachments]
            |> Map.values()
            |> Enum.map(fn attachment ->
              %{
                "filename" => attachment["filename"],
                "content_type" => attachment["content_type"],
                "encoding" => "base64",
                # Already Base64 encoded
                "data" => attachment["data"]
              }
            end)

          Map.put(body, "attachments", attachments_list)
        else
          body
        end

      # CRITICAL: Validate all string fields before JSON encoding
      # Log any fields that might cause JSON encoding to fail
      Enum.each(body, fn {key, value} ->
        if is_binary(value) && !String.valid?(value) do
          require Logger

          Logger.error(
            "HarakaClient: Field '#{key}' has invalid UTF-8 before JSON encode: #{inspect(value, limit: 50)}"
          )
        end
      end)

      Jason.encode!(body)
    end
  end

  # Extract email address and display name from "Display Name <email@domain.com>" format
  defp extract_email_and_name(from_field) do
    case Regex.run(~r/^"?([^"]*?)"?\s*<([^>]+)>$/, String.trim(from_field)) do
      [_, name, email] ->
        {String.trim(email), String.trim(name)}

      _ ->
        # If no display name format, just return the email
        {String.trim(from_field), nil}
    end
  end

  # Convert recipients to the format the HTTP API expects
  defp normalize_recipients_for_api(nil), do: nil
  defp normalize_recipients_for_api(recipients) when is_list(recipients), do: recipients

  defp normalize_recipients_for_api(recipients) when is_binary(recipients) do
    recipients
    |> String.split(~r/[,;]\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      [single] -> single
      multiple -> multiple
    end
  end

  # Ensure a field is valid UTF-8 for JSON encoding
  # Jason.encode! will crash on invalid UTF-8 bytes
  defp ensure_field_utf8_safe(nil), do: ""
  defp ensure_field_utf8_safe(""), do: ""

  defp ensure_field_utf8_safe(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      # Invalid UTF-8, sanitize it
      require Logger

      Logger.warning(
        "HarakaClient: Invalid UTF-8 detected in field, sanitizing: #{inspect(value, limit: 50)}"
      )

      Elektrine.Email.Sanitizer.sanitize_utf8(value)
    end
  end

  defp ensure_field_utf8_safe(value) when is_list(value) do
    # Handle list of recipients
    Enum.map(value, &ensure_field_utf8_safe/1)
  end

  defp ensure_field_utf8_safe(value), do: value

  defp add_internal_origin_headers(params) do
    case System.get_env("HARAKA_INTERNAL_SIGNING_SECRET") do
      secret when is_binary(secret) and secret != "" ->
        ts = Integer.to_string(System.system_time(:second))
        payload = internal_origin_payload(params[:from], ts)
        signature = Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)
        existing_headers = if is_map(params[:headers]), do: params[:headers], else: %{}

        signed_headers =
          existing_headers
          |> Map.put("X-Elektrine-Origin", "internal")
          |> Map.put("X-Elektrine-Origin-Ts", ts)
          |> Map.put("X-Elektrine-Origin-Sig", signature)

        Map.put(params, :headers, signed_headers)

      _ ->
        params
    end
  end

  defp internal_origin_payload(from_address, ts) do
    {email, _name} = extract_email_and_name(from_address || "")
    clean_email = String.trim(email) |> String.downcase()
    "internal|#{ts}|#{clean_email}"
  end

  @doc """
  Encodes a string using RFC 2047 MIME encoding for email headers.
  This is required for non-ASCII characters in headers like Subject, From, To.

  Uses Base64 encoding (=?UTF-8?B?...?=) which is more reliable than quoted-printable
  for CJK characters and other complex scripts.
  """
  def encode_mime_header(nil), do: ""
  def encode_mime_header(""), do: ""

  def encode_mime_header(text) when is_binary(text) do
    # Check if text contains any non-ASCII characters
    if contains_non_ascii?(text) do
      # Use Base64 encoding for non-ASCII text (RFC 2047)
      # Format: =?charset?encoding?encoded_text?=
      encoded = Base.encode64(text)
      "=?UTF-8?B?#{encoded}?="
    else
      # ASCII-only text doesn't need encoding
      text
    end
  end

  # Check if string contains any non-ASCII characters (codepoint > 127)
  defp contains_non_ascii?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn char -> char > 127 end)
  end
end
