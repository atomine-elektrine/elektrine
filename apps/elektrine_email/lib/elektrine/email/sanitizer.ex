defmodule Elektrine.Email.Sanitizer do
  @moduledoc "Unified email sanitization module for all email paths (incoming, outgoing, forwarding).\n\nThis is the ONLY module you should use for email sanitization. It provides:\n- HTML content scrubbing (removes scripts, dangerous tags, event handlers)\n- Header sanitization (prevents SMTP injection)\n- UTF-8 validation and fixing\n- Comprehensive protection across all email paths\n\n## Usage\n\n    # Incoming emails\n    sanitized = Sanitizer.sanitize_incoming_email(email_params)\n\n    # Outgoing emails\n    sanitized = Sanitizer.sanitize_outgoing_email(email_params)\n\n    # Just HTML content\n    safe_html = Sanitizer.sanitize_html_content(html_string)\n\n## Do NOT use ElektrineWeb.EmailScrubber directly\n\nEmailScrubber is an internal implementation detail. Always use this module instead.\n"
  alias Elektrine.Email.HeaderSanitizer
  alias HtmlSanitizeEx.Scrubber

  @doc "Sanitizes an incoming email before storage.\n\nApplies:\n- Header sanitization (from, to, cc, bcc, subject)\n- HTML content scrubbing\n- UTF-8 validation\n\nSpecial handling for PGP encrypted/signed emails:\n- Preserves PGP blocks intact (BEGIN/END markers and content)\n- Skips aggressive HTML sanitization for PGP content\n"
  def sanitize_incoming_email(email_params) do
    if is_pgp_email?(email_params) do
      require Logger

      Logger.info(
        "PGP email detected - using minimal sanitization to preserve encryption/signatures"
      )

      email_params |> sanitize_headers() |> sanitize_pgp_email_content()
    else
      email_params |> sanitize_headers() |> sanitize_body_content()
    end
  end

  @doc "Sanitizes an outgoing email before sending.\n\nApplies:\n- Header sanitization (from, to, cc, bcc, subject, reply_to)\n- HTML content scrubbing\n- UTF-8 validation\n"
  def sanitize_outgoing_email(email_params) do
    email_params |> sanitize_headers() |> sanitize_body_content()
  end

  @doc "Light sanitization for forwarded emails.\n\n⚠️ DEPRECATED: Use `sanitize_incoming_email/1` instead for consistent security.\n\nThis function provides minimal sanitization (UTF-8 fixes only) but is NOT\nrecommended for production use. Forwarded emails should go through the same\nsecurity sanitization as regular incoming emails.\n\nOnly applies:\n- Header sanitization (prevent SMTP injection)\n- UTF-8 validation and encoding fixes\n- NO HTML stripping or tag removal\n\nFor security reasons, use `sanitize_incoming_email/1` instead, which:\n- Removes dangerous tags (script, iframe, form, etc.)\n- Removes event handlers (onclick, etc.)\n- Removes dangerous protocols\n- While still preserving safe links and formatting\n"
  def sanitize_forwarded_email(email_params) do
    email_params |> sanitize_headers() |> sanitize_forwarded_body_content()
  end

  defp sanitize_forwarded_body_content(email_params) when is_map(email_params) do
    email_params |> sanitize_forwarded_html_body() |> sanitize_forwarded_text_body()
  end

  defp sanitize_forwarded_html_body(params) do
    use_atoms = is_map_key(params, :html_body)
    html_content = Map.get(params, "html_body") || Map.get(params, :html_body)

    case html_content do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        sanitized = fix_utf8_for_forwarding(content)

        if use_atoms do
          Map.put(params, :html_body, sanitized)
        else
          Map.put(params, "html_body", sanitized)
        end

      _ ->
        params
    end
  end

  defp sanitize_forwarded_text_body(params) do
    use_atoms = is_map_key(params, :text_body)
    text_content = Map.get(params, "text_body") || Map.get(params, :text_body)

    case text_content do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        sanitized = fix_utf8_for_forwarding(content)

        if use_atoms do
          Map.put(params, :text_body, sanitized)
        else
          Map.put(params, "text_body", sanitized)
        end

      _ ->
        params
    end
  end

  defp fix_utf8_for_forwarding(content) when is_binary(content) do
    case String.valid?(content) do
      true ->
        content |> remove_null_bytes() |> fix_common_encoding_issues()

      false ->
        case :unicode.characters_to_binary(content, :latin1, :utf8) do
          result when is_binary(result) ->
            if String.valid?(result) do
              result |> remove_null_bytes() |> fix_common_encoding_issues()
            else
              force_valid_utf8(content)
            end

          _ ->
            force_valid_utf8(content)
        end
    end
  end

  defp force_valid_utf8(content) when is_binary(content) do
    result =
      String.codepoints(content)
      |> Enum.map_join("", fn codepoint ->
        if String.valid?(codepoint) do
          codepoint
        else
          "�"
        end
      end)
      |> remove_null_bytes()

    if String.valid?(result) do
      fix_common_encoding_issues(result)
    else
      content
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte -> "\\x#{Integer.to_string(byte, 16)}" end)
    end
  end

  @doc "Sanitizes email headers to prevent SMTP injection and other attacks.\n"
  def sanitize_headers(email_params) when is_map(email_params) do
    email_params
    |> sanitize_header_field("from", :from)
    |> sanitize_header_field("to", :to)
    |> sanitize_header_field("cc", :cc)
    |> sanitize_header_field("bcc", :bcc)
    |> sanitize_header_field("reply_to", :reply_to)
    |> sanitize_header_field("subject", :subject)
  end

  defp sanitize_header_field(params, string_field, atom_field) when is_map(params) do
    cond do
      Map.has_key?(params, atom_field) ->
        sanitize_header_value(params, atom_field, string_field)

      Map.has_key?(params, string_field) ->
        sanitize_header_value(params, string_field, string_field)

      true ->
        params
    end
  end

  defp sanitize_header_value(params, key, field_type) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        sanitized =
          if field_type == "subject" do
            HeaderSanitizer.sanitize_subject_header(value)
          else
            HeaderSanitizer.sanitize_email_header(value)
          end

        Map.put(params, key, sanitized)

      _ ->
        params
    end
  end

  @doc "Sanitizes email body content (both HTML and text).\n"
  def sanitize_body_content(email_params) when is_map(email_params) do
    email_params |> sanitize_html_body() |> sanitize_text_body()
  end

  defp sanitize_html_body(params) do
    use_atoms = is_map_key(params, :html_body)
    html_content = Map.get(params, "html_body") || Map.get(params, :html_body)

    case html_content do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        sanitized = sanitize_html_content(content)

        if use_atoms do
          Map.put(params, :html_body, sanitized)
        else
          Map.put(params, "html_body", sanitized)
        end

      _ ->
        params
    end
  end

  defp sanitize_text_body(params) do
    use_atoms = is_map_key(params, :text_body)
    text_content = Map.get(params, "text_body") || Map.get(params, :text_body)

    case text_content do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        sanitized = sanitize_utf8(content)

        if use_atoms do
          Map.put(params, :text_body, sanitized)
        else
          Map.put(params, "text_body", sanitized)
        end

      _ ->
        params
    end
  end

  @doc "Sanitizes HTML content using comprehensive scrubbing.\n\nThis is the core HTML sanitization function that:\n1. Ensures valid UTF-8\n2. Removes dangerous tags (script, iframe, form, etc.)\n3. Removes event handlers (onclick, onload, etc.)\n4. Removes dangerous protocols (javascript:, vbscript:, etc.)\n5. Uses EmailScrubber for comprehensive allowlist-based scrubbing\n"
  def sanitize_html_content(html_content) when is_binary(html_content) do
    html_content
    |> ensure_valid_utf8()
    |> remove_dangerous_tags()
    |> remove_event_handlers()
    |> remove_dangerous_protocols()
    |> scrub_with_email_scrubber()
  end

  def sanitize_html_content(nil) do
    nil
  end

  def sanitize_html_content("") do
    ""
  end

  defp fix_common_encoding_issues(content) when is_binary(content) do
    if has_clear_mojibake_pattern?(content) do
      content
      |> String.replace(<<195, 162, 226, 130, 172, 226, 132, 162>>, "’")
      |> String.replace(<<195, 162, 226, 130, 172, 203, 156>>, "‘")
      |> String.replace(<<195, 162, 226, 130, 172, 197, 147>>, "\"")
      |> String.replace(<<195, 130, 194, 169>>, "©")
      |> String.replace(<<195, 130, 194, 174>>, "®")
    else
      content
    end
  end

  defp fix_common_encoding_issues(content) do
    content
  end

  defp has_clear_mojibake_pattern?(content) do
    String.contains?(content, <<195, 162, 226, 130, 172>>) ||
      String.contains?(content, <<195, 130, 194, 169>>) ||
      String.contains?(content, <<195, 130, 194, 174>>)
  end

  defp ensure_valid_utf8(content) do
    case String.valid?(content) do
      true ->
        fix_common_encoding_issues(content)

      false ->
        case :unicode.characters_to_binary(content, :latin1, :utf8) do
          binary when is_binary(binary) ->
            if String.valid?(binary) do
              fix_common_encoding_issues(binary)
            else
              force_valid_utf8(content)
            end

          {:error, good, _bad} when is_binary(good) ->
            if String.valid?(good) do
              fix_common_encoding_issues(good)
            else
              force_valid_utf8(content)
            end

          _ ->
            force_valid_utf8(content)
        end
    end
  end

  defp remove_dangerous_tags(content) do
    content
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<script[^>]*>/i, "")
    |> String.replace(~r/<\/script>/i, "")
    |> String.replace(~r/<meta[^>]*http-equiv[^>]*>/i, "")
    |> String.replace(
      ~r/<link[^>]*rel=["']?(?:prefetch|preconnect|dns-prefetch|modulepreload|preload|import)[^>]*>/i,
      ""
    )
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/<frame[^>]*>.*?<\/frame>/is, "")
    |> String.replace(~r/<frameset[^>]*>.*?<\/frameset>/is, "")
    |> String.replace(~r/<object[^>]*>.*?<\/object>/is, "")
    |> String.replace(~r/<embed[^>]*>/is, "")
    |> String.replace(~r/<applet[^>]*>.*?<\/applet>/is, "")
    |> String.replace(~r/<form[^>]*>.*?<\/form>/is, "")
    |> String.replace(~r/<input[^>]*>/is, "")
    |> String.replace(~r/<textarea[^>]*>.*?<\/textarea>/is, "")
    |> String.replace(~r/<select[^>]*>.*?<\/select>/is, "")
  end

  defp remove_event_handlers(content) do
    content
    |> String.replace(~r/\son\w+\s*=\s*["'][^"']*["']/i, "")
    |> String.replace(~r/\son\w+\s*=\s*[^\s>]+/i, "")
  end

  defp remove_dangerous_protocols(content) do
    content
    |> String.replace(~r/javascript\s*:/i, "")
    |> String.replace(~r/vbscript\s*:/i, "")
    |> String.replace(~r/data\s*:\s*text\/html/i, "")
  end

  defp scrub_with_email_scrubber(content) do
    Scrubber.scrub(content, ElektrineWeb.EmailScrubber)
  rescue
    _error -> content
  end

  @doc "Sanitizes UTF-8 content (for text bodies and other text fields).\nGUARANTEES valid UTF-8 output suitable for JSON encoding and PostgreSQL.\nRemoves null bytes which PostgreSQL does not allow in text fields.\n"
  def sanitize_utf8(content) when is_binary(content) do
    case String.valid?(content) do
      true ->
        result = content |> remove_null_bytes() |> fix_common_encoding_issues()

        if String.valid?(result) do
          result
        else
          force_valid_utf8(content)
        end

      false ->
        :unicode.characters_to_binary(content, :latin1, :utf8)
        |> case do
          result when is_binary(result) ->
            if String.valid?(result) do
              fixed = result |> remove_null_bytes() |> fix_common_encoding_issues()

              if String.valid?(fixed) do
                fixed
              else
                force_valid_utf8(content)
              end
            else
              force_valid_utf8(content)
            end

          _ ->
            force_valid_utf8(content)
        end
    end
  end

  def sanitize_utf8(nil) do
    ""
  end

  def sanitize_utf8("") do
    ""
  end

  defp remove_null_bytes(content) when is_binary(content) do
    String.replace(content, <<0>>, "")
  end

  defp remove_null_bytes(content) do
    content
  end

  @doc "Validates and sanitizes email addresses.\nDelegates to HeaderSanitizer for actual validation.\n"
  def sanitize_email_address(email) when is_binary(email) do
    HeaderSanitizer.sanitize_email_header(email)
  end

  def sanitize_email_address(nil) do
    nil
  end

  def sanitize_email_address("") do
    ""
  end

  defp normalize_attachments(attachments) when is_list(attachments) do
    attachments
  end

  defp normalize_attachments(attachments) when is_map(attachments) do
    Map.values(attachments)
  end

  defp normalize_attachments(_) do
    []
  end

  defp is_pgp_email?(email_params) when is_map(email_params) do
    text_body = Map.get(email_params, "text_body") || Map.get(email_params, :text_body) || ""
    html_body = Map.get(email_params, "html_body") || Map.get(email_params, :html_body) || ""
    plain_body = Map.get(email_params, "plain_body") || Map.get(email_params, :plain_body) || ""

    content_type =
      Map.get(email_params, "content_type") || Map.get(email_params, :content_type) || ""

    raw_attachments =
      Map.get(email_params, "attachments") || Map.get(email_params, :attachments) || []

    attachments = normalize_attachments(raw_attachments)

    has_pgp_block =
      String.contains?(text_body, "-----BEGIN PGP") ||
        String.contains?(html_body, "-----BEGIN PGP") ||
        String.contains?(plain_body, "-----BEGIN PGP")

    has_pgp_mime =
      String.contains?(content_type, "multipart/encrypted") ||
        String.contains?(content_type, "multipart/signed") ||
        String.contains?(content_type, "application/pgp")

    has_pgp_attachment =
      Enum.any?(attachments, fn attachment ->
        ct = attachment["content_type"] || attachment["mime_type"] || ""
        name = attachment["filename"] || attachment["name"] || ""

        String.contains?(ct, "application/pgp") ||
          (String.contains?(ct, "application/octet-stream") && String.ends_with?(name, ".asc")) ||
          String.ends_with?(name, ".gpg") || String.ends_with?(name, ".pgp")
      end)

    has_pgp_block || has_pgp_mime || has_pgp_attachment
  end

  defp sanitize_pgp_email_content(email_params) when is_map(email_params) do
    result =
      email_params
      |> sanitize_pgp_body_field("text_body")
      |> sanitize_pgp_body_field("html_body")
      |> sanitize_pgp_body_field("plain_body")
      |> sanitize_pgp_body_field(:text_body)
      |> sanitize_pgp_body_field(:html_body)
      |> sanitize_pgp_body_field(:plain_body)

    validate_all_fields_utf8(result)
  end

  defp sanitize_pgp_body_field(params, field) when is_map(params) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        sanitized = content |> remove_null_bytes() |> ensure_minimal_utf8()
        Map.put(params, field, sanitized)

      _ ->
        params
    end
  end

  defp ensure_minimal_utf8(content) when is_binary(content) do
    if String.valid?(content) do
      content
    else
      require Logger
      Logger.warning("Invalid UTF-8 detected in PGP content - attempting safe recovery")

      String.codepoints(content)
      |> Enum.map(fn codepoint ->
        if String.valid?(codepoint) do
          codepoint
        else
          "�"
        end
      end)
      |> Enum.map_join("", & &1)
    end
  end

  defp validate_all_fields_utf8(params) when is_map(params) do
    Enum.reduce(params, params, fn {key, value}, acc ->
      validated_value =
        case value do
          v when is_binary(v) ->
            if String.valid?(v) do
              v
            else
              require Logger

              Logger.error(
                "Field '#{key}' has invalid UTF-8 after PGP sanitization - forcing valid"
              )

              force_valid_utf8(v)
            end

          _ ->
            value
        end

      Map.put(acc, key, validated_value)
    end)
  end
end
