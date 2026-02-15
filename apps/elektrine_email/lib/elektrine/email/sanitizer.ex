defmodule Elektrine.Email.Sanitizer do
  @moduledoc """
  Unified email sanitization module for all email paths (incoming, outgoing, forwarding).

  This is the ONLY module you should use for email sanitization. It provides:
  - HTML content scrubbing (removes scripts, dangerous tags, event handlers)
  - Header sanitization (prevents SMTP injection)
  - UTF-8 validation and fixing
  - Comprehensive protection across all email paths

  ## Usage

      # Incoming emails
      sanitized = Sanitizer.sanitize_incoming_email(email_params)

      # Outgoing emails
      sanitized = Sanitizer.sanitize_outgoing_email(email_params)

      # Just HTML content
      safe_html = Sanitizer.sanitize_html_content(html_string)

  ## Do NOT use ElektrineWeb.EmailScrubber directly

  EmailScrubber is an internal implementation detail. Always use this module instead.
  """

  alias Elektrine.Email.HeaderSanitizer
  alias HtmlSanitizeEx.Scrubber

  @doc """
  Sanitizes an incoming email before storage.

  Applies:
  - Header sanitization (from, to, cc, bcc, subject)
  - HTML content scrubbing
  - UTF-8 validation

  Special handling for PGP encrypted/signed emails:
  - Preserves PGP blocks intact (BEGIN/END markers and content)
  - Skips aggressive HTML sanitization for PGP content
  """
  def sanitize_incoming_email(email_params) do
    # Check if this is a PGP email before sanitizing
    if is_pgp_email?(email_params) do
      require Logger

      Logger.info(
        "PGP email detected - using minimal sanitization to preserve encryption/signatures"
      )

      email_params
      |> sanitize_headers()
      |> sanitize_pgp_email_content()
    else
      email_params
      |> sanitize_headers()
      |> sanitize_body_content()
    end
  end

  @doc """
  Sanitizes an outgoing email before sending.

  Applies:
  - Header sanitization (from, to, cc, bcc, subject, reply_to)
  - HTML content scrubbing
  - UTF-8 validation
  """
  def sanitize_outgoing_email(email_params) do
    email_params
    |> sanitize_headers()
    |> sanitize_body_content()
  end

  @doc """
  Light sanitization for forwarded emails.

  ⚠️ DEPRECATED: Use `sanitize_incoming_email/1` instead for consistent security.

  This function provides minimal sanitization (UTF-8 fixes only) but is NOT
  recommended for production use. Forwarded emails should go through the same
  security sanitization as regular incoming emails.

  Only applies:
  - Header sanitization (prevent SMTP injection)
  - UTF-8 validation and encoding fixes
  - NO HTML stripping or tag removal

  For security reasons, use `sanitize_incoming_email/1` instead, which:
  - Removes dangerous tags (script, iframe, form, etc.)
  - Removes event handlers (onclick, etc.)
  - Removes dangerous protocols
  - While still preserving safe links and formatting
  """
  def sanitize_forwarded_email(email_params) do
    email_params
    |> sanitize_headers()
    |> sanitize_forwarded_body_content()
  end

  defp sanitize_forwarded_body_content(email_params) when is_map(email_params) do
    email_params
    |> sanitize_forwarded_html_body()
    |> sanitize_forwarded_text_body()
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
        # ONLY fix UTF-8 encoding - preserve ALL HTML content for forwarding
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
        # ONLY fix UTF-8 encoding - preserve all content for forwarding
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

  # Ultra-light UTF-8 fixing for forwarded emails - NO content modification except encoding
  defp fix_utf8_for_forwarding(content) when is_binary(content) do
    case String.valid?(content) do
      true ->
        # Valid UTF-8, but may have double-encoding artifacts or null bytes - fix those
        content
        |> remove_null_bytes()
        |> fix_common_encoding_issues()

      false ->
        # Invalid UTF-8 - try multiple strategies to fix it
        # Strategy 1: Assume it's Latin-1/ISO-8859-1 and convert to UTF-8
        case :unicode.characters_to_binary(content, :latin1, :utf8) do
          result when is_binary(result) ->
            # Check if result is now valid UTF-8
            if String.valid?(result) do
              result
              |> remove_null_bytes()
              |> fix_common_encoding_issues()
            else
              # Still invalid, try strategy 2
              force_valid_utf8(content)
            end

          _ ->
            # Conversion failed, force valid UTF-8
            force_valid_utf8(content)
        end
    end
  end

  # Force content to be valid UTF-8 by replacing invalid sequences
  # This function GUARANTEES valid UTF-8 output suitable for PostgreSQL
  defp force_valid_utf8(content) when is_binary(content) do
    # Try to extract valid UTF-8, replacing invalid bytes with U+FFFD (�)
    result =
      String.codepoints(content)
      |> Enum.map_join("", fn codepoint ->
        if String.valid?(codepoint) do
          codepoint
        else
          # Invalid codepoint, replace with replacement character
          "�"
        end
      end)
      |> remove_null_bytes()

    # Verify result is valid UTF-8 (should always be true now)
    if String.valid?(result) do
      fix_common_encoding_issues(result)
    else
      # Last resort: convert each byte to its hex representation
      # This ensures we ALWAYS return valid UTF-8
      content
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte -> "\\x#{Integer.to_string(byte, 16)}" end)
    end
  end

  @doc """
  Sanitizes email headers to prevent SMTP injection and other attacks.
  """
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

  @doc """
  Sanitizes email body content (both HTML and text).
  """
  def sanitize_body_content(email_params) when is_map(email_params) do
    email_params
    |> sanitize_html_body()
    |> sanitize_text_body()
  end

  defp sanitize_html_body(params) do
    # Detect if using atom or string keys
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
    # Detect if using atom or string keys
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

  @doc """
  Sanitizes HTML content using comprehensive scrubbing.

  This is the core HTML sanitization function that:
  1. Ensures valid UTF-8
  2. Removes dangerous tags (script, iframe, form, etc.)
  3. Removes event handlers (onclick, onload, etc.)
  4. Removes dangerous protocols (javascript:, vbscript:, etc.)
  5. Uses EmailScrubber for comprehensive allowlist-based scrubbing
  """
  def sanitize_html_content(html_content) when is_binary(html_content) do
    html_content
    |> ensure_valid_utf8()
    |> remove_dangerous_tags()
    |> remove_event_handlers()
    |> remove_dangerous_protocols()
    |> scrub_with_email_scrubber()
  end

  def sanitize_html_content(nil), do: nil
  def sanitize_html_content(""), do: ""

  # Fix double-encoded UTF-8 patterns ONLY when they're clearly mojibake
  # IMPORTANT: Be very careful not to corrupt valid CJK characters!
  # Only fix patterns that are clearly double-encoded Western characters
  defp fix_common_encoding_issues(content) when is_binary(content) do
    # Only apply fixes if the content appears to have double-encoding issues
    # (contains specific mojibake patterns that are unlikely to be valid text)
    if has_clear_mojibake_pattern?(content) do
      content
      # Fix common double-encoded UTF-8 patterns for Western punctuation ONLY
      # These specific byte sequences are very unlikely to appear in valid CJK text
      # Smart single quote
      |> String.replace(<<0xC3, 0xA2, 0xE2, 0x82, 0xAC, 0xE2, 0x84, 0xA2>>, "\u2019")
      # Left single quote
      |> String.replace(<<0xC3, 0xA2, 0xE2, 0x82, 0xAC, 0xCB, 0x9C>>, "\u2018")
      # Left double quote
      |> String.replace(<<0xC3, 0xA2, 0xE2, 0x82, 0xAC, 0xC5, 0x93>>, "\"")
      # Copyright
      |> String.replace(<<0xC3, 0x82, 0xC2, 0xA9>>, "\u00A9")
      # Registered
      |> String.replace(<<0xC3, 0x82, 0xC2, 0xAE>>, "\u00AE")

      # DO NOT replace standalone characters or CJK-looking patterns!
      # They may be valid characters in Chinese/Japanese/Korean text
    else
      # Content looks clean, don't risk corrupting it
      content
    end
  end

  defp fix_common_encoding_issues(content), do: content

  # Check if content has clear double-encoding mojibake patterns
  # These patterns are very specific and unlikely to appear in valid text
  defp has_clear_mojibake_pattern?(content) do
    # Only trigger fixes for very specific Western smart quote mojibake patterns
    # Use byte sequences to avoid false positives with valid CJK text
    # Pattern for double-encoded smart quotes (UTF-8 interpreted as Latin-1 then re-encoded)
    # Common prefix for smart quotes
    # Copyright
    # Registered
    String.contains?(content, <<0xC3, 0xA2, 0xE2, 0x82, 0xAC>>) ||
      String.contains?(content, <<0xC3, 0x82, 0xC2, 0xA9>>) ||
      String.contains?(content, <<0xC3, 0x82, 0xC2, 0xAE>>)
  end

  # Ensure valid UTF-8 encoding
  defp ensure_valid_utf8(content) do
    case String.valid?(content) do
      true ->
        # Even if valid, fix double-encoding issues
        fix_common_encoding_issues(content)

      false ->
        # Convert from Latin-1 to UTF-8 for invalid sequences
        case :unicode.characters_to_binary(content, :latin1, :utf8) do
          binary when is_binary(binary) ->
            # Verify the result is actually valid UTF-8
            if String.valid?(binary) do
              fix_common_encoding_issues(binary)
            else
              # Still invalid, force it
              force_valid_utf8(content)
            end

          {:error, good, _bad} when is_binary(good) ->
            # Verify good part is actually valid
            if String.valid?(good) do
              fix_common_encoding_issues(good)
            else
              force_valid_utf8(content)
            end

          _ ->
            # Fallback to forcing valid UTF-8
            force_valid_utf8(content)
        end
    end
  end

  # Remove dangerous tags
  # Note: style and button tags are allowed through EmailScrubber
  defp remove_dangerous_tags(content) do
    content
    # Remove script tags - multiple passes to catch variations and malformed tags
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    # Catch unclosed script tags
    |> String.replace(~r/<script[^>]*>/i, "")
    # Catch orphaned closing tags
    |> String.replace(~r/<\/script>/i, "")
    # Don't strip style tags - EmailScrubber handles them safely
    # |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    # Remove dangerous meta tags (http-equiv redirects, etc.) but allow charset
    |> String.replace(~r/<meta[^>]*http-equiv[^>]*>/i, "")
    # Remove dangerous link tags but ALLOW stylesheet links (for external fonts)
    # Only remove: prefetch, preconnect, dns-prefetch, modulepreload, import
    |> String.replace(
      ~r/<link[^>]*rel=["']?(?:prefetch|preconnect|dns-prefetch|modulepreload|preload|import)[^>]*>/i,
      ""
    )
    # Allow: <link rel="stylesheet"> for external fonts and styles
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/<frame[^>]*>.*?<\/frame>/is, "")
    |> String.replace(~r/<frameset[^>]*>.*?<\/frameset>/is, "")
    |> String.replace(~r/<object[^>]*>.*?<\/object>/is, "")
    |> String.replace(~r/<embed[^>]*>/is, "")
    |> String.replace(~r/<applet[^>]*>.*?<\/applet>/is, "")
    |> String.replace(~r/<form[^>]*>.*?<\/form>/is, "")
    |> String.replace(~r/<input[^>]*>/is, "")
    # Don't strip button tags - EmailScrubber handles them safely
    # |> String.replace(~r/<button[^>]*>.*?<\/button>/is, "")
    |> String.replace(~r/<textarea[^>]*>.*?<\/textarea>/is, "")
    |> String.replace(~r/<select[^>]*>.*?<\/select>/is, "")
  end

  # Remove event handlers
  defp remove_event_handlers(content) do
    content
    |> String.replace(~r/\son\w+\s*=\s*["'][^"']*["']/i, "")
    |> String.replace(~r/\son\w+\s*=\s*[^\s>]+/i, "")
  end

  # Remove dangerous protocols
  defp remove_dangerous_protocols(content) do
    content
    |> String.replace(~r/javascript\s*:/i, "")
    |> String.replace(~r/vbscript\s*:/i, "")
    |> String.replace(~r/data\s*:\s*text\/html/i, "")
  end

  # Use EmailScrubber for comprehensive allowlist-based scrubbing
  defp scrub_with_email_scrubber(content) do
    try do
      Scrubber.scrub(content, ElektrineWeb.EmailScrubber)
    rescue
      _error -> content
    end
  end

  @doc """
  Sanitizes UTF-8 content (for text bodies and other text fields).
  GUARANTEES valid UTF-8 output suitable for JSON encoding and PostgreSQL.
  Removes null bytes which PostgreSQL does not allow in text fields.
  """
  def sanitize_utf8(content) when is_binary(content) do
    case String.valid?(content) do
      true ->
        # Even if valid UTF-8, might have double-encoding issues or null bytes
        result =
          content
          |> remove_null_bytes()
          |> fix_common_encoding_issues()

        # Double-check result is still valid after fixes
        if String.valid?(result), do: result, else: force_valid_utf8(content)

      false ->
        # Convert invalid UTF-8: treat bytes as Latin-1 and convert to UTF-8
        :unicode.characters_to_binary(content, :latin1, :utf8)
        |> case do
          result when is_binary(result) ->
            # CRITICAL: Verify the conversion produced valid UTF-8
            if String.valid?(result) do
              fixed =
                result
                |> remove_null_bytes()
                |> fix_common_encoding_issues()

              # Verify fixes didn't break it
              if String.valid?(fixed), do: fixed, else: force_valid_utf8(content)
            else
              # Conversion didn't produce valid UTF-8, force it
              force_valid_utf8(content)
            end

          _ ->
            # Conversion failed completely, force valid UTF-8
            force_valid_utf8(content)
        end
    end
  end

  # Return empty string, not nil
  def sanitize_utf8(nil), do: ""
  def sanitize_utf8(""), do: ""

  # Remove null bytes which PostgreSQL does not allow in text fields
  # Even though null bytes can be valid in some UTF-8 contexts, PostgreSQL rejects them
  defp remove_null_bytes(content) when is_binary(content) do
    String.replace(content, <<0>>, "")
  end

  defp remove_null_bytes(content), do: content

  @doc """
  Validates and sanitizes email addresses.
  Delegates to HeaderSanitizer for actual validation.
  """
  def sanitize_email_address(email) when is_binary(email) do
    HeaderSanitizer.sanitize_email_header(email)
  end

  def sanitize_email_address(nil), do: nil
  def sanitize_email_address(""), do: ""

  # Normalize attachments to a list format
  # Handles both list format and map format (e.g., from Haraka: %{"attachment_0" => %{...}})
  defp normalize_attachments(attachments) when is_list(attachments), do: attachments
  defp normalize_attachments(attachments) when is_map(attachments), do: Map.values(attachments)
  defp normalize_attachments(_), do: []

  # PGP Email Detection and Handling

  # Detects if an email contains PGP encrypted or signed content.
  # Checks for:
  # - PGP armor blocks (BEGIN PGP MESSAGE, BEGIN PGP SIGNED MESSAGE, BEGIN PGP SIGNATURE)
  # - PGP MIME types (multipart/encrypted, application/pgp-encrypted, application/pgp-signature)
  # - PGP-related attachments
  defp is_pgp_email?(email_params) when is_map(email_params) do
    text_body = Map.get(email_params, "text_body") || Map.get(email_params, :text_body) || ""
    html_body = Map.get(email_params, "html_body") || Map.get(email_params, :html_body) || ""
    plain_body = Map.get(email_params, "plain_body") || Map.get(email_params, :plain_body) || ""

    content_type =
      Map.get(email_params, "content_type") || Map.get(email_params, :content_type) || ""

    raw_attachments =
      Map.get(email_params, "attachments") || Map.get(email_params, :attachments) || []

    # Handle both list and map formats for attachments (Haraka sends map with "attachment_0", etc.)
    attachments = normalize_attachments(raw_attachments)

    # Check for PGP armor blocks in any body content
    has_pgp_block =
      String.contains?(text_body, "-----BEGIN PGP") ||
        String.contains?(html_body, "-----BEGIN PGP") ||
        String.contains?(plain_body, "-----BEGIN PGP")

    # Check for PGP MIME types in content-type header
    has_pgp_mime =
      String.contains?(content_type, "multipart/encrypted") ||
        String.contains?(content_type, "multipart/signed") ||
        String.contains?(content_type, "application/pgp")

    # Check for PGP in attachments (PGP/MIME sends encrypted data as attachment)
    has_pgp_attachment =
      Enum.any?(attachments, fn attachment ->
        ct = attachment["content_type"] || attachment["mime_type"] || ""
        name = attachment["filename"] || attachment["name"] || ""

        String.contains?(ct, "application/pgp") ||
          (String.contains?(ct, "application/octet-stream") && String.ends_with?(name, ".asc")) ||
          String.ends_with?(name, ".gpg") ||
          String.ends_with?(name, ".pgp")
      end)

    has_pgp_block || has_pgp_mime || has_pgp_attachment
  end

  # Sanitizes PGP email content with minimal processing to preserve encryption/signatures.
  # Only applies:
  # - UTF-8 validation (replaces invalid bytes, preserves valid content)
  # - Null byte removal (PostgreSQL requirement)
  # - NO HTML tag stripping
  # - NO regex replacements
  # - NO content modification beyond UTF-8 safety
  # GUARANTEES valid UTF-8 output for PostgreSQL while preserving PGP armor.
  defp sanitize_pgp_email_content(email_params) when is_map(email_params) do
    result =
      email_params
      |> sanitize_pgp_body_field("text_body")
      |> sanitize_pgp_body_field("html_body")
      |> sanitize_pgp_body_field("plain_body")
      |> sanitize_pgp_body_field(:text_body)
      |> sanitize_pgp_body_field(:html_body)
      |> sanitize_pgp_body_field(:plain_body)

    # Final validation: ensure all string fields are valid UTF-8
    validate_all_fields_utf8(result)
  end

  defp sanitize_pgp_body_field(params, field) when is_map(params) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        params

      content when is_binary(content) ->
        # Minimal sanitization: only remove null bytes and ensure valid UTF-8
        sanitized =
          content
          |> remove_null_bytes()
          |> ensure_minimal_utf8()

        Map.put(params, field, sanitized)

      _ ->
        params
    end
  end

  # Minimal UTF-8 validation for PGP content - preserves all characters
  # PGP armor is base64 (ASCII subset) and SHOULD always be valid UTF-8
  # If it's not, replace ONLY the invalid bytes without changing the rest
  defp ensure_minimal_utf8(content) when is_binary(content) do
    if String.valid?(content) do
      # Already valid UTF-8 - return as-is (most common case for PGP)
      content
    else
      # Invalid UTF-8 detected in PGP content
      # This is unusual - PGP armor should be pure ASCII
      require Logger
      Logger.warning("Invalid UTF-8 detected in PGP content - attempting safe recovery")

      # Strategy: Replace invalid bytes with U+FFFD (replacement character)
      # This ensures PostgreSQL compatibility while preserving PGP structure
      String.codepoints(content)
      |> Enum.map(fn codepoint ->
        if String.valid?(codepoint) do
          codepoint
        else
          # U+FFFD replacement character
          "�"
        end
      end)
      |> Enum.map_join("", & &1)
    end
  end

  # Validate all string fields in the params map are valid UTF-8
  # CRITICAL: PostgreSQL will reject invalid UTF-8
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

              # This should never happen if ensure_minimal_utf8 works correctly
              force_valid_utf8(v)
            end

          _ ->
            value
        end

      Map.put(acc, key, validated_value)
    end)
  end
end
