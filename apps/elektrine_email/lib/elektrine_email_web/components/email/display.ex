defmodule ElektrineEmailWeb.Components.Email.Display do
  @moduledoc "Email display and processing utilities for sanitizing and formatting email content.\n"
  @doc "Cleans already-decoded email HTML without guessing its transfer encoding.\n"
  def process_email_html(html_content) when is_binary(html_content) do
    html_content
    |> ensure_valid_utf8()
    |> String.replace(~r/^Subject:[^\r\n]*[\r\n]+/mi, "")
    |> String.replace(
      ~r/^(From|To|Cc|Bcc|Date|Message-ID|Reply-To|In-Reply-To|References):[^\r\n]*[\r\n]+/mi,
      ""
    )
    |> remove_css_before_html()
    |> clean_email_artifacts()
    |> String.trim()
  end

  def process_email_html(nil) do
    nil
  end

  @doc "Makes stored plain text safe to render without interpreting or reformatting it."
  def clean_plain_text_body(text) when is_binary(text) do
    ensure_valid_utf8(text)
  end

  def clean_plain_text_body(nil), do: ""

  defp remove_css_before_html(content) do
    cond do
      String.starts_with?(content, "Facebook@media") ->
        case Regex.run(~r/(<[a-zA-Z][^>]*>.*)/s, content) do
          [_, html] -> html
          _ -> ""
        end

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

  @doc "Cleans email artifacts like standalone CSS and MIME headers from email content.\n"
  def clean_email_artifacts(content) when is_binary(content) do
    content
    |> remove_facebook_css_text()
    |> remove_standalone_css()
    |> clean_mime_artifacts()
    |> clean_outlook_artifacts()
    |> normalize_whitespace()
  end

  def clean_email_artifacts(nil) do
    nil
  end

  defp remove_facebook_css_text(content) do
    case Regex.run(~r/^(.*?)(<[a-zA-Z].*)/s, content) do
      [_, prefix, html_content] ->
        if contains_css_patterns?(prefix) do
          html_content
        else
          content
        end

      _ ->
        if contains_css_patterns?(content) and not String.contains?(content, "<") do
          ""
        else
          content |> remove_all_css_blocks()
        end
    end
  end

  defp contains_css_patterns?(text) do
    (String.contains?(text, "{") and String.contains?(text, "}")) or
      String.contains?(text, "@media") or String.contains?(text, ".d_mb_") or
      String.contains?(text, ".mb_") or Regex.match?(~r/\.[a-zA-Z_-]+\s*\{/, text) or
      Regex.match?(~r/\*\[class\]/, text)
  end

  defp remove_all_css_blocks(content) do
    content
    |> String.replace(~r/^[^<>]*\{[^}]*\}[^<>]*/s, "")
    |> String.replace(~r/@media[^{]*\{[^}]*\}/s, "")
    |> String.replace(~r/\.[a-zA-Z_-]+[^{]*\{[^}]*\}/s, "")
    |> String.replace(~r/[a-zA-Z0-9_\-\.\#\*\[\]]+\s*\{[^}]*\}/s, "")
    |> String.trim()
  end

  defp remove_standalone_css(content) do
    content
    |> String.replace(~r/Facebook@media all and \(max-width: 480px\)\{.*?\}[^<]*/s, "")
    |> String.replace(~r/^[^<]*@media[^{]*\{.*?\}[^<]*/s, "")
    |> String.replace(~r/^[^<]*\.[a-zA-Z_][^{]*\{.*?\}[^<]*/s, "")
    |> String.replace(~r/^[^<]*\*\[[^]]*\][^{]*\{.*?\}[^<]*/s, "")
    |> String.replace(~r/^[^<]*[a-zA-Z_\*\.\#\[].*?\{.*?\}[^<]*/s, "")
    |> remove_sequential_css_blocks()
    |> remove_leading_css_blocks()
    |> String.trim()
  end

  defp remove_sequential_css_blocks(content) do
    content
    |> String.replace(
      ~r/@media[^{]*\{[^}]*\}\.d_mb_show\{[^}]*\}\.d_mb_flex\{[^}]*\}@media[^{]*\{[^}]*\}/s,
      ""
    )
    |> String.replace(~r/\*\[class\][^{]*\{[^}]*\}(\*\[class\][^{]*\{[^}]*\})+/s, "")
  end

  defp remove_leading_css_blocks(content) do
    case String.split(content, ~r/<[a-zA-Z]/, parts: 2) do
      [css_part, html_part] ->
        if (String.contains?(css_part, "{") and String.contains?(css_part, "}")) or
             String.contains?(css_part, "@media") or String.contains?(css_part, "Facebook@media") or
             Regex.match?(~r/\*\[class\]/, css_part) do
          "<" <> html_part
        else
          content
        end

      [_] ->
        if (String.contains?(content, "{") and String.contains?(content, "}") and
              not String.contains?(content, "<")) or String.contains?(content, "Facebook@media") or
             (String.contains?(content, "@media") and not String.contains?(content, "<")) do
          ""
        else
          content
        end
    end
  end

  defp clean_mime_artifacts(content) do
    content
    |> String.replace(~r/^--[^\r\n]+[\r\n]*/m, "")
    |> String.replace(~r/^Subject:[^\r\n]*[\r\n]*/mi, "")
    |> String.replace(~r/Content-Type:[^\r\n]*[\r\n]*/i, "")
    |> String.replace(~r/Content-Transfer-Encoding:[^\r\n]*[\r\n]*/i, "")
    |> String.replace(~r/Content-Disposition:[^\r\n]*[\r\n]*/i, "")
    |> String.replace(
      ~r/^(From|To|Cc|Bcc|Date|Message-ID|Reply-To|In-Reply-To|References):[^\r\n]*[\r\n]*/mi,
      ""
    )
    |> String.replace(~r/^[A-Za-z-]+:\s*[^\r\n]*[\r\n]*/m, "")
    |> String.trim()
  end

  defp normalize_whitespace(content) do
    content
    |> String.replace(~r/\r\n|\r|\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp clean_outlook_artifacts(content) do
    content
    |> String.replace(~r/<!--\[if.*?\]>/s, "")
    |> String.replace(~r/<!\[endif\]-->/s, "")
    |> String.replace(~r/xmlns:[a-z]="[^"]*"/i, "")
    |> String.replace(~r/<o:p>\s*<\/o:p>/s, "")
    |> String.replace(~r/<o:p\s*\/>/s, "")
  end

  @doc "Formats email addresses for display, removing redundant quotes when email is used as display name\n"
  def format_email_display(email_string) when is_binary(email_string) do
    case Regex.run(~r/^"([^"]+)"\s*<([^>]+)>$/, email_string) do
      [_, display_name, email_address] ->
        if display_name == email_address do
          email_address
        else
          email_string
        end

      _ ->
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

  def format_email_display(nil) do
    ""
  end

  @doc "Safely processes and sanitizes email HTML content, with error handling for encoding issues.\n"
  def safe_sanitize_email_html(html_content) do
    Elektrine.Email.Sanitizer.sanitize_html_content(html_content)
  end

  @doc "Permissive HTML sanitization that preserves styling while maintaining security.\nAllows background colors, images, tables, and most formatting for rich email display.\n"
  def permissive_email_sanitize(nil) do
    nil
  end

  def permissive_email_sanitize(html_content) when is_binary(html_content) do
    Elektrine.Email.Sanitizer.sanitize_html_content(html_content)
  end

  @doc "Safely converts an email message to JSON, excluding associations and metadata.\n"
  def safe_message_to_json(message) do
    clean_map =
      message
      |> Map.from_struct()
      |> Map.drop([:__meta__, :mailbox, :user])
      |> sanitize_map_for_json()

    Jason.encode!(clean_map, pretty: true)
  rescue
    error ->
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

  defp safe_get(data, key) do
    Map.get(data, key)
  rescue
    _ -> nil
  end

  defp sanitize_map_for_json(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, sanitize_value_for_json(value))
    end)
  end

  defp sanitize_value_for_json(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp sanitize_value_for_json(%NaiveDateTime{} = ndt) do
    NaiveDateTime.to_iso8601(ndt)
  end

  defp sanitize_value_for_json(%Date{} = d) do
    Date.to_iso8601(d)
  end

  defp sanitize_value_for_json(%Time{} = t) do
    Time.to_iso8601(t)
  end

  defp sanitize_value_for_json(value) when is_map(value) do
    if Map.has_key?(value, :__struct__) do
      "#{inspect(value.__struct__)}"
    else
      sanitize_map_for_json(value)
    end
  end

  defp sanitize_value_for_json(value) do
    value
  end

  defp format_datetime_for_json(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime_for_json(%NaiveDateTime{} = ndt) do
    NaiveDateTime.to_iso8601(ndt)
  end

  defp format_datetime_for_json(value) do
    value
  end

  @doc "Decodes email subject that may be RFC 2047 encoded.\n"
  def decode_email_subject(nil) do
    "(No Subject)"
  end

  def decode_email_subject("") do
    "(No Subject)"
  end

  def decode_email_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    if trimmed == "" do
      "(No Subject)"
    else
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

            ensure_valid_utf8(decoded)

          _ ->
            match
        end
      end)
      |> ensure_valid_utf8()
      |> String.trim()
    end
  end

  defp decode_quoted_printable_simple(content) when is_binary(content) do
    result =
      content
      |> String.replace(~r/=\r?\n/, "")
      |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn match ->
        hex = String.slice(match, 1, 2)

        case Integer.parse(hex, 16) do
          {value, ""} -> <<value>>
          _ -> match
        end
      end)

    ensure_valid_utf8(result)
  end

  defp ensure_valid_utf8(content) when is_binary(content) do
    content
    |> replace_invalid_utf8()
    |> String.replace(<<0>>, "")
  end

  defp ensure_valid_utf8(content) do
    content
  end

  defp replace_invalid_utf8(content), do: replace_invalid_utf8(content, [])

  defp replace_invalid_utf8(content, acc) do
    case :unicode.characters_to_binary(content, :utf8, :utf8) do
      valid when is_binary(valid) ->
        IO.iodata_to_binary(Enum.reverse([valid | acc]))

      {:error, valid, <<_invalid, rest::binary>>} ->
        replace_invalid_utf8(rest, ["�", valid | acc])

      {:incomplete, valid, _rest} ->
        IO.iodata_to_binary(Enum.reverse(["�", valid | acc]))
    end
  end
end
