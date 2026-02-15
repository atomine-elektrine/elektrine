defmodule ElektrineWeb.Components.Email.Display do
  @moduledoc """
  Email display and processing utilities for sanitizing and formatting email content.
  """

  @doc """
  Processes email HTML content, handling various encodings and cleaning up display issues.
  """
  def process_email_html(html_content) when is_binary(html_content) do
    html_content
    |> ensure_valid_utf8()
    |> decode_if_base64()
    |> decode_if_quoted_printable()
    |> ensure_valid_utf8()
    # Remove email headers that might be in the content
    |> String.replace(~r/^Subject:[^\r\n]*[\r\n]+/mi, "")
    |> String.replace(
      ~r/^(From|To|Cc|Bcc|Date|Message-ID|Reply-To|In-Reply-To|References):[^\r\n]*[\r\n]+/mi,
      ""
    )
    |> remove_css_before_html()
    |> clean_email_artifacts()
    |> String.trim()
  end

  def process_email_html(nil), do: nil

  # Simple aggressive CSS removal - removes everything before first HTML tag
  defp remove_css_before_html(content) do
    cond do
      # If it starts with Facebook@media, remove everything up to actual content
      String.starts_with?(content, "Facebook@media") ->
        # Find the first HTML tag
        case Regex.run(~r/(<[a-zA-Z][^>]*>.*)/s, content) do
          [_, html] -> html
          # No HTML found, return empty
          _ -> ""
        end

      # If it starts with any CSS-like pattern, remove it
      String.starts_with?(content, "@media") or
          (String.starts_with?(content, ".") and
             String.contains?(String.slice(content, 0, 100), "{")) ->
        case Regex.run(~r/(<[a-zA-Z][^>]*>.*)/s, content) do
          [_, html] -> html
          _ -> content
        end

      true ->
        content
    end
  end

  @doc """
  Cleans email artifacts like standalone CSS and MIME headers from email content.
  """
  def clean_email_artifacts(content) when is_binary(content) do
    content
    |> remove_facebook_css_text()
    |> remove_standalone_css()
    |> clean_mime_artifacts()
    |> clean_outlook_artifacts()
    |> normalize_whitespace()
  end

  def clean_email_artifacts(nil), do: nil

  # Specifically remove Facebook email CSS that appears as text
  defp remove_facebook_css_text(content) do
    # Remove ALL CSS that appears before actual content
    # This handles any CSS text that appears at the beginning

    # First, try to find where HTML content starts
    case Regex.run(~r/^(.*?)(<[a-zA-Z].*)/s, content) do
      [_, prefix, html_content] ->
        # Check if the prefix contains CSS-like patterns
        if contains_css_patterns?(prefix) do
          # Remove the CSS prefix entirely, keep only HTML
          html_content
        else
          # No CSS patterns, keep original content
          content
        end

      _ ->
        # No HTML found, check if entire content is CSS
        if contains_css_patterns?(content) and not String.contains?(content, "<") do
          # It's all CSS, remove it entirely
          ""
        else
          # Try to find any text after CSS blocks
          content
          |> remove_all_css_blocks()
        end
    end
  end

  # Check if content contains CSS patterns
  defp contains_css_patterns?(text) do
    (String.contains?(text, "{") and String.contains?(text, "}")) or
      String.contains?(text, "@media") or
      String.contains?(text, ".d_mb_") or
      String.contains?(text, ".mb_") or
      Regex.match?(~r/\.[a-zA-Z_-]+\s*\{/, text) or
      Regex.match?(~r/\*\[class\]/, text)
  end

  # Remove all CSS blocks from content
  defp remove_all_css_blocks(content) do
    content
    # Remove any CSS-like content before first real text
    |> String.replace(~r/^[^<>]*\{[^}]*\}[^<>]*/s, "")
    # Remove @media queries and their content
    |> String.replace(~r/@media[^{]*\{[^}]*\}/s, "")
    # Remove class selectors and their rules
    |> String.replace(~r/\.[a-zA-Z_-]+[^{]*\{[^}]*\}/s, "")
    # Remove any remaining CSS selectors
    |> String.replace(~r/[a-zA-Z0-9_\-\.\#\*\[\]]+\s*\{[^}]*\}/s, "")
    |> String.trim()
  end

  # Remove standalone CSS blocks that appear outside of proper HTML structure
  defp remove_standalone_css(content) do
    content
    # Remove the specific Facebook CSS pattern that appears as text
    |> String.replace(~r/Facebook@media all and \(max-width: 480px\)\{.*?\}[^<]*/s, "")
    # Remove general @media patterns
    |> String.replace(~r/^[^<]*@media[^{]*\{.*?\}[^<]*/s, "")
    # Remove CSS class definitions
    |> String.replace(~r/^[^<]*\.[a-zA-Z_][^{]*\{.*?\}[^<]*/s, "")
    # Remove orphaned CSS rules with selectors like *[class]
    |> String.replace(~r/^[^<]*\*\[[^]]*\][^{]*\{.*?\}[^<]*/s, "")
    # Remove any text that starts with CSS selectors and contains curly braces
    |> String.replace(~r/^[^<]*[a-zA-Z_\*\.\#\[].*?\{.*?\}[^<]*/s, "")
    # Remove multiple CSS blocks in sequence
    |> remove_sequential_css_blocks()
    # Remove CSS blocks that appear before HTML content
    |> remove_leading_css_blocks()
    |> String.trim()
  end

  # Remove multiple CSS blocks that appear in sequence
  defp remove_sequential_css_blocks(content) do
    # This handles cases where there are multiple @media or CSS rules in a row
    content
    |> String.replace(
      ~r/@media[^{]*\{[^}]*\}\.d_mb_show\{[^}]*\}\.d_mb_flex\{[^}]*\}@media[^{]*\{[^}]*\}/s,
      ""
    )
    |> String.replace(~r/\*\[class\][^{]*\{[^}]*\}(\*\[class\][^{]*\{[^}]*\})+/s, "")
  end

  # Remove CSS blocks that appear before any HTML content
  defp remove_leading_css_blocks(content) do
    # Split content to find where HTML actually starts
    case String.split(content, ~r/<[a-zA-Z]/, parts: 2) do
      [css_part, html_part] ->
        # If the first part contains CSS rules or CSS-like patterns, remove them
        if (String.contains?(css_part, "{") and String.contains?(css_part, "}")) or
             String.contains?(css_part, "@media") or
             String.contains?(css_part, "Facebook@media") or
             Regex.match?(~r/\*\[class\]/, css_part) do
          "<" <> html_part
        else
          content
        end

      [_] ->
        # No HTML tags found, check if it's all CSS-like content
        if (String.contains?(content, "{") and String.contains?(content, "}") and
              not String.contains?(content, "<")) or
             String.contains?(content, "Facebook@media") or
             (String.contains?(content, "@media") and not String.contains?(content, "<")) do
          ""
        else
          content
        end
    end
  end

  # Clean MIME artifacts and headers
  defp clean_mime_artifacts(content) do
    content
    # Remove MIME boundary markers
    |> String.replace(~r/^--[^\r\n]+[\r\n]*/m, "")
    # Remove Subject headers that might be in the body
    |> String.replace(~r/^Subject:[^\r\n]*[\r\n]*/mi, "")
    # Remove Content-Type headers that might be mixed in
    |> String.replace(~r/Content-Type:[^\r\n]*[\r\n]*/i, "")
    |> String.replace(~r/Content-Transfer-Encoding:[^\r\n]*[\r\n]*/i, "")
    |> String.replace(~r/Content-Disposition:[^\r\n]*[\r\n]*/i, "")
    # Remove other common email headers (From, To, Date, etc.)
    |> String.replace(
      ~r/^(From|To|Cc|Bcc|Date|Message-ID|Reply-To|In-Reply-To|References):[^\r\n]*[\r\n]*/mi,
      ""
    )
    # Remove other common MIME headers
    |> String.replace(~r/^[A-Za-z-]+:\s*[^\r\n]*[\r\n]*/m, "")
    |> String.trim()
  end

  # Normalize whitespace and line breaks
  defp normalize_whitespace(content) do
    content
    |> String.replace(~r/\r\n|\r|\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # Clean Outlook/Microsoft Office specific artifacts
  defp clean_outlook_artifacts(content) do
    content
    # Remove MSO conditional comments but keep their content
    |> String.replace(~r/<!--\[if.*?\]>/s, "")
    |> String.replace(~r/<!\[endif\]-->/s, "")
    # Remove XML namespace declarations that might interfere
    |> String.replace(~r/xmlns:[a-z]="[^"]*"/i, "")
    # Clean up empty Office tags
    |> String.replace(~r/<o:p>\s*<\/o:p>/s, "")
    |> String.replace(~r/<o:p\s*\/>/s, "")
  end

  @doc """
  Formats email addresses for display, removing redundant quotes when email is used as display name
  """
  def format_email_display(email_string) when is_binary(email_string) do
    # Pattern: "email@example.com" <email@example.com>
    case Regex.run(~r/^"([^"]+)"\s*<([^>]+)>$/, email_string) do
      [_, display_name, email_address] ->
        # If display name is the same as email address, just show the email
        if display_name == email_address do
          email_address
        else
          email_string
        end

      _ ->
        # Also handle without quotes: email@example.com <email@example.com>
        case Regex.run(~r/^([^\s<]+)\s*<([^>]+)>$/, email_string) do
          [_, display_name, email_address] ->
            if display_name == email_address do
              email_address
            else
              email_string
            end

          _ ->
            email_string
        end
    end
  end

  def format_email_display(nil), do: ""

  @doc """
  Safely processes and sanitizes email HTML content, with error handling for encoding issues.
  """
  def safe_sanitize_email_html(html_content) do
    # Delegate to the unified Sanitizer module
    # This ensures consistent sanitization across all email paths
    Elektrine.Email.Sanitizer.sanitize_html_content(html_content)
  end

  @doc """
  Permissive HTML sanitization that preserves styling while maintaining security.
  Allows background colors, images, tables, and most formatting for rich email display.
  """
  def permissive_email_sanitize(nil), do: nil

  def permissive_email_sanitize(html_content) when is_binary(html_content) do
    # Delegate to the unified Sanitizer module
    try do
      Elektrine.Email.Sanitizer.sanitize_html_content(html_content)
    rescue
      _ ->
        # If sanitization fails, fall back to basic_html but don't lose all content
        try do
          case HtmlSanitizeEx.basic_html(html_content) do
            "" ->
              # If basic_html strips everything, try stripping only scripts/dangerous tags
              strip_dangerous_tags(html_content)

            result ->
              result
          end
        rescue
          # If basic_html also fails due to malformed HTML, strip dangerous tags manually
          _ -> strip_dangerous_tags(html_content)
        end
    end
  end

  # Manually strip dangerous tags when HTML parsing fails
  defp strip_dangerous_tags(html_content) do
    html_content
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<link[^>]*>/is, "")
    |> String.replace(~r/<meta[^>]*>/is, "")
    |> String.replace(~r/<form[^>]*>.*?<\/form>/is, "")
    |> String.replace(~r/javascript:/i, "")
    |> String.replace(~r/on\w+\s*=/i, "")
  end

  @doc """
  Safely converts an email message to JSON, excluding associations and metadata.
  """
  def safe_message_to_json(message) do
    try do
      # Convert struct to map and clean up associations
      clean_map =
        message
        |> Map.from_struct()
        # Drop common associations
        |> Map.drop([:__meta__, :mailbox, :user])
        |> sanitize_map_for_json()

      Jason.encode!(clean_map, pretty: true)
    rescue
      error ->
        # Fallback: create a simplified JSON representation
        fallback = %{
          error: "Could not serialize message to JSON: #{inspect(error)}",
          id: safe_get(message, :id),
          subject: safe_get(message, :subject),
          from: safe_get(message, :from),
          to: safe_get(message, :to),
          cc: safe_get(message, :cc),
          bcc: safe_get(message, :bcc),
          status: safe_get(message, :status),
          inserted_at: safe_get(message, :inserted_at) |> format_datetime_for_json()
        }

        Jason.encode!(fallback, pretty: true)
    end
  end

  # Helper to safely get values from maps/structs
  defp safe_get(data, key) do
    try do
      Map.get(data, key)
    rescue
      _ -> nil
    end
  end

  # Helper to sanitize map values for JSON encoding
  defp sanitize_map_for_json(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, sanitize_value_for_json(value))
    end)
  end

  # Helper to sanitize individual values for JSON
  defp sanitize_value_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_value_for_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp sanitize_value_for_json(%Date{} = d), do: Date.to_iso8601(d)
  defp sanitize_value_for_json(%Time{} = t), do: Time.to_iso8601(t)

  defp sanitize_value_for_json(value) when is_map(value) do
    # For nested maps, recursively sanitize
    if Map.has_key?(value, :__struct__) do
      # Just show the struct name
      "#{inspect(value.__struct__)}"
    else
      sanitize_map_for_json(value)
    end
  end

  defp sanitize_value_for_json(value), do: value

  # Helper to format DateTime for JSON safely
  defp format_datetime_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime_for_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_datetime_for_json(value), do: value

  @doc """
  Decodes email subject that may be RFC 2047 encoded.
  """
  def decode_email_subject(nil), do: "(No Subject)"
  def decode_email_subject(""), do: "(No Subject)"

  def decode_email_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    if trimmed == "" do
      "(No Subject)"
    else
      # Pattern: =?charset?encoding?encoded-text?=
      subject
      |> ensure_valid_utf8()
      |> String.replace(~r/=\?([^?]+)\?([QqBb])\?([^?]*)\?=/, fn match ->
        case Regex.run(~r/=\?([^?]+)\?([QqBb])\?([^?]*)\?=/, match) do
          [_, _charset, encoding, encoded_text] ->
            decoded =
              case String.upcase(encoding) do
                "Q" ->
                  decode_quoted_printable_simple(encoded_text |> String.replace("_", " "))

                "B" ->
                  case Base.decode64(encoded_text) do
                    {:ok, decoded} -> decoded
                    :error -> match
                  end

                _ ->
                  match
              end

            # Ensure the decoded result is valid UTF-8
            ensure_valid_utf8(decoded)

          _ ->
            match
        end
      end)
      |> ensure_valid_utf8()
      |> String.trim()
    end
  end

  # Simple quoted-printable decoding for subjects
  defp decode_quoted_printable_simple(content) when is_binary(content) do
    result =
      content
      # Remove soft line breaks
      |> String.replace(~r/=\r?\n/, "")
      |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn match ->
        hex = String.slice(match, 1, 2)

        case Integer.parse(hex, 16) do
          {value, ""} -> <<value>>
          _ -> match
        end
      end)

    # Ensure result is valid UTF-8
    ensure_valid_utf8(result)
  end

  # Try to decode content if it appears to be base64
  defp decode_if_base64(content) when is_binary(content) do
    # Check if content looks like base64 (only contains base64 chars and is reasonably long)
    if String.match?(content, ~r/^[A-Za-z0-9+\/=\s]+$/) and String.length(content) > 100 and
         rem(String.length(String.replace(content, ~r/\s/, "")), 4) == 0 do
      case Base.decode64(String.replace(content, ~r/\s/, "")) do
        {:ok, decoded} ->
          # Ensure decoded content is valid UTF-8
          decoded = ensure_valid_utf8(decoded)
          # Check if decoded content looks like HTML
          if String.contains?(decoded, "<") and String.contains?(decoded, ">") do
            decoded
          else
            content
          end

        :error ->
          content
      end
    else
      content
    end
  end

  defp decode_if_base64(content), do: content

  # Ensures the content is valid UTF-8, converting invalid sequences to replacement characters
  defp ensure_valid_utf8(content) when is_binary(content) do
    case String.valid?(content) do
      true ->
        # Even if valid UTF-8, might have double-encoding issues
        fix_common_encoding_issues(content)

      false ->
        # Convert invalid UTF-8 to valid UTF-8 by replacing invalid sequences
        # This prevents UnicodeConversionError while preserving as much content as possible
        :unicode.characters_to_binary(content, :latin1, :utf8)
        |> case do
          result when is_binary(result) ->
            fix_common_encoding_issues(result)

          {:error, _valid, _rest} ->
            # Fallback: try to scrub the content
            scrub_invalid_utf8(content)

          {:incomplete, _valid, _rest} ->
            # Fallback: try to scrub the content
            scrub_invalid_utf8(content)
        end
    end
  end

  defp ensure_valid_utf8(content), do: content

  # Fix common UTF-8 encoding issues often seen in emails
  defp fix_common_encoding_issues(content) when is_binary(content) do
    content
    # Fix common double-encoded UTF-8 issues
    |> fix_encoding_patterns()
    # Fix some quoted-printable remnants that might have been missed
    |> String.replace("=\r\n", "")
    |> String.replace("=\n", "")
  end

  # Fix encoding patterns using binary matching to avoid source code issues
  defp fix_encoding_patterns(content) do
    content
    # Smart single quote
    |> String.replace(~r/â€™/, "'")
    # Smart double quote open
    |> String.replace(~r/â€œ/, "\"")
    # Smart double quote close
    |> String.replace(~r/â€/, "\"")
    # En dash -> regular dash
    |> String.replace(~r/â€"/, "-")
    # Em dash -> regular dash
    |> String.replace(~r/â€"/, "-")
    # Ellipsis
    |> String.replace(~r/â€¦/, "...")
    # Copyright
    |> String.replace(~r/Â©/, "©")
    # Registered
    |> String.replace(~r/Â®/, "®")
    # Non-breaking space to regular space
    |> String.replace(~r/Â /, " ")
    # Standalone Â to space
    |> String.replace(~r/Â/, " ")
    # Thin space variations
    |> String.replace(~r/â¯/, " ")
    # Em dash variations
    |> String.replace(~r/â/, "-")
    # German quote
    |> String.replace(~r/â€ž/, "\"")
  end

  # Fallback function to scrub invalid UTF-8 characters
  defp scrub_invalid_utf8(content) do
    content
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      # Replace bytes that would cause UTF-8 issues with space
      if byte < 32 and byte not in [9, 10, 13] do
        # space
        32
      else
        byte
      end
    end)
    |> :binary.list_to_bin()
    |> then(fn result ->
      # If still invalid, use a more aggressive approach
      case String.valid?(result) do
        true ->
          result

        false ->
          # Last resort: convert each byte to a safe representation
          for <<byte <- content>>,
            into: "",
            do: if(byte >= 32 and byte <= 126, do: <<byte>>, else: "?")
      end
    end)
  end

  # Try to decode content if it appears to be quoted-printable
  defp decode_if_quoted_printable(content) when is_binary(content) do
    # Check if content looks like quoted-printable
    # Look for =XX hex patterns, soft line breaks (= at end of line), or common QP sequences
    has_hex_encoding = String.match?(content, ~r/=[0-9A-Fa-f]{2}/)
    has_soft_breaks = String.match?(content, ~r/=\r?\n/)

    has_common_qp =
      String.contains?(content, "=3D") or String.contains?(content, "=20") or
        String.contains?(content, "=E2=80") or String.contains?(content, "=C2=A0")

    # For emails, be more aggressive about QP detection
    has_email_qp_indicators =
      String.contains?(content, "href=3D") or
        String.contains?(content, "style=3D") or
        String.contains?(content, "&amp;") or
        String.contains?(content, "=\r\n") or
        String.contains?(content, "=\n")

    if has_hex_encoding or has_soft_breaks or has_common_qp or has_email_qp_indicators do
      decode_quoted_printable_full(content)
    else
      content
    end
  end

  defp decode_if_quoted_printable(content), do: content

  # Full quoted-printable decoding for email bodies
  defp decode_quoted_printable_full(content) when is_binary(content) do
    result =
      content
      # Remove soft line breaks (= at end of line) - handle both CRLF and LF
      |> String.replace(~r/=\r?\n/, "")
      |> String.replace(~r/=\r/, "")
      # Decode =XX hex sequences
      |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn match ->
        hex = String.slice(match, 1, 2)

        case Integer.parse(hex, 16) do
          {value, ""} -> <<value>>
          _ -> match
        end
      end)
      # Handle any remaining = at end of lines that might have been missed
      |> String.replace(~r/=(?=\s*$)/m, "")

    # Ensure result is valid UTF-8
    ensure_valid_utf8(result)
  end
end
