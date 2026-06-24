defmodule Elektrine.Email.Sanitizer do
  @moduledoc "Unified email sanitization module for all email paths (incoming, outgoing, forwarding).\n\nThis is the ONLY module you should use for email sanitization. It provides:\n- Permissive HTML filtering for email markup, styles, and layout attributes\n- Removal of active/dangerous content such as scripts, event handlers, and unsafe URL protocols\n- Header sanitization (prevents SMTP injection)\n- UTF-8 validation and fixing\n- Comprehensive protection across all email paths\n\n## Usage\n\n    # Incoming emails\n    sanitized = Sanitizer.sanitize_incoming_email(email_params)\n\n    # Outgoing emails\n    sanitized = Sanitizer.sanitize_outgoing_email(email_params)\n\n    # Just HTML content\n    safe_html = Sanitizer.sanitize_html_content(html_string)\n"
  alias Elektrine.Email.HeaderSanitizer

  @literal_html_fragment_pattern ~r/<\/?(?:html|head|body|table|thead|tbody|tfoot|tr|th|td|div|p|span|br|a|img|style|section|article|h[1-6])\b/i
  @encoded_html_fragment_pattern ~r/&lt;\s*(?:!doctype\b|\/?\s*(?:html|head|body|table|thead|tbody|tfoot|tr|th|td|div|p|span|br|a|img|style|section|article|h[1-6])\b)/i
  @dangerous_url_attribute_pattern ~r/\s((?:href|src|srcset|poster|background|cite|longdesc|xlink:href|action|formaction)\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i

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

  @doc "Sanitizes HTML content using permissive email-safe filtering.\n\nThis is the core HTML sanitization function that:\n1. Ensures valid UTF-8\n2. Preserves email layout markup, attributes, inline styles, and CSS\n3. Removes active/dangerous tags (script, iframe, form controls, etc.)\n4. Removes event handlers (onclick, onload, etc.)\n5. Removes dangerous URL protocols (javascript:, vbscript:, data:text/html)\n"
  def sanitize_html_content(html_content) when is_binary(html_content) do
    html_content
    |> ensure_valid_utf8()
    |> maybe_decode_entity_encoded_html()
    |> sanitize_email_markup()
  end

  def sanitize_html_content(nil) do
    nil
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

  defp maybe_decode_entity_encoded_html(content) do
    if entity_encoded_html_fragment?(content) and not literal_html_fragment?(content) do
      HtmlEntities.decode(content)
    else
      content
    end
  end

  defp entity_encoded_html_fragment?(content) do
    @encoded_html_fragment_pattern
    |> Regex.scan(content)
    |> length()
    |> Kernel.>=(2)
  end

  defp literal_html_fragment?(content) do
    Regex.match?(@literal_html_fragment_pattern, content)
  end

  defp remove_dangerous_tags(content) do
    content
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<script[^>]*>/i, "")
    |> String.replace(~r/<\/script>/i, "")
    |> String.replace(~r/<base[^>]*>/i, "")
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
    |> String.replace(~r/<svg[^>]*>.*?<\/svg>/is, "")
    |> String.replace(~r/<svg[^>]*>/i, "")
    |> String.replace(~r/<\/svg>/i, "")
    |> String.replace(~r/<math[^>]*>.*?<\/math>/is, "")
    |> String.replace(~r/<math[^>]*>/i, "")
    |> String.replace(~r/<\/math>/i, "")
    |> String.replace(~r/<applet[^>]*>.*?<\/applet>/is, "")
    |> String.replace(~r/<form[^>]*>/i, "")
    |> String.replace(~r/<\/form>/i, "")
    |> String.replace(~r/<input[^>]*>/is, "")
    |> String.replace(~r/<textarea[^>]*>(.*?)<\/textarea>/is, "\\1")
    |> String.replace(~r/<select[^>]*>(.*?)<\/select>/is, "\\1")
  end

  defp remove_processing_instructions(content) do
    String.replace(content, ~r/<\?[^>]*\?>/s, "")
  end

  defp remove_doctype_declarations(content) do
    String.replace(content, ~r/<!doctype[^>]*>/i, "")
  end

  defp remove_xml_namespace_attributes(content) do
    String.replace(
      content,
      ~r/\s+xmlns(?::[A-Za-z_][\w.-]*)?\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i,
      ""
    )
  end

  defp remove_outlook_conditional_comments(content) do
    content
    |> preserve_non_mso_conditional_content()
    |> remove_mso_conditional_content()
    |> strip_conditional_comment_markers()
  end

  defp preserve_non_mso_conditional_content(content) do
    content
    |> String.replace(
      ~r/<!--\s*\[if\s+!mso[^\]]*\]>\s*(?:<!-->|<!--\s*-->)\s*(.*?)\s*<!--\s*<!\s*\[endif\]\s*-->/is,
      "\\1"
    )
    |> String.replace(
      ~r/<!--\s*\[if\s+!mso[^\]]*\]>\s*(.*?)\s*<!\s*\[endif\]\s*-->/is,
      "\\1"
    )
  end

  defp remove_mso_conditional_content(content) do
    String.replace(
      content,
      ~r/<!--\s*\[if\s+(?!\s*!mso\b)[^\]]*(?:\bmso\b|\bIE\b)[^\]]*\]>.*?<!\s*\[endif\]\s*-->/is,
      ""
    )
  end

  defp strip_conditional_comment_markers(content) do
    content
    |> String.replace(~r/<!--\s*\[if.*?\]>\s*(?:<!-->|<!--\s*-->)/is, "")
    |> String.replace(~r/<!--\s*\[if.*?\]>/is, "")
    |> String.replace(~r/<!--\s*<!\s*\[endif\]\s*-->/i, "")
    |> String.replace(~r/<!\s*\[endif\]\s*-->/i, "")
  end

  defp remove_event_handlers(content) do
    content
    |> String.replace(~r/[\s\/]on\w+\s*=\s*["'][^"']*["']/i, "")
    |> String.replace(~r/[\s\/]on\w+\s*=\s*[^\s>]+/i, "")
  end

  defp remove_dangerous_protocols(content) do
    Regex.replace(@dangerous_url_attribute_pattern, content, fn full,
                                                                prefix,
                                                                double_quoted,
                                                                single_quoted,
                                                                unquoted ->
      value = first_present([double_quoted, single_quoted, unquoted])
      attribute = prefix |> String.split("=", parts: 2) |> List.first() |> String.trim()

      if dangerous_url_attribute?(attribute, value) do
        ""
      else
        full
      end
    end)
  end

  defp remove_dangerous_css(content) do
    content
    |> remove_dangerous_css_urls()
    |> String.replace(~r/expression\s*\([^)]*\)/i, "")
    |> String.replace(~r/(?:behavior|-moz-binding)\s*:\s*url\s*\([^)]*\)\s*;?/i, "")
  end

  defp remove_dangerous_css_urls(content) do
    content
    |> replace_quoted_css_urls()
    |> replace_unquoted_css_urls()
  end

  defp replace_quoted_css_urls(content) do
    Regex.replace(~r/url\(\s*(["'])(.*?)\1\s*\)/is, content, fn full, _quote, value ->
      if dangerous_url?(value), do: "none", else: full
    end)
  end

  defp replace_unquoted_css_urls(content) do
    Regex.replace(~r/url\(\s*(.*?)\s*\)+(?=\s*[;>}])/is, content, fn full, value ->
      if dangerous_url?(value), do: "none", else: full
    end)
  end

  defp sanitize_email_markup(content) when is_binary(content) do
    content
    |> remove_processing_instructions()
    |> remove_doctype_declarations()
    |> remove_xml_namespace_attributes()
    |> remove_outlook_conditional_comments()
    |> remove_dangerous_tags()
    |> remove_dangerous_attributes()
    |> remove_event_handlers()
    |> remove_dangerous_protocols()
    |> remove_dangerous_css()
  end

  defp remove_dangerous_attributes(content) do
    String.replace(
      content,
      ~r/\s(?:action|formaction|method|enctype|srcdoc)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i,
      ""
    )
  end

  defp dangerous_url_attribute?(attribute, value) do
    attribute = String.downcase(attribute || "")

    if attribute == "srcset" do
      value
      |> String.split(",")
      |> Enum.any?(fn entry ->
        entry
        |> String.trim()
        |> String.split(~r/\s+/, parts: 2)
        |> List.first()
        |> dangerous_url?()
      end)
    else
      dangerous_url?(value)
    end
  end

  defp dangerous_url?(value) when is_binary(value) do
    normalized =
      value
      |> HtmlEntities.decode()
      |> String.replace(~r/[\x00-\x1F\x7F\s]+/u, "")
      |> String.downcase()

    String.starts_with?(normalized, "javascript:") or
      String.starts_with?(normalized, "vbscript:") or
      String.starts_with?(normalized, "data:text/html")
  end

  defp dangerous_url?(_value), do: false

  defp first_present(values) do
    Enum.find(values, "", &(&1 not in [nil, ""]))
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
