defmodule Elektrine.IMAP.Response do
  @moduledoc """
  Response formatting and building functions for IMAP server.
  Handles construction of RFC822 messages, envelopes, body structures,
  and FETCH responses.
  """

  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.IMAP.Helpers

  @doc "Build FETCH response for a message"
  def build_fetch_response(msg, seq_num, items, current_folder, user_id) do
    needs_full_message = Enum.any?(items, &fetch_item_needs_full_message?/1)
    full_msg = if needs_full_message, do: load_and_decrypt_message(msg, user_id), else: nil
    rfc822_cache = if full_msg, do: build_rfc822_message(full_msg), else: nil

    parts =
      (["UID #{msg.id}"] ++
         Enum.map(items, fn item ->
           build_fetch_item(
             item,
             msg,
             full_msg,
             rfc822_cache,
             current_folder
           )
         end))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    "* #{seq_num} FETCH (#{parts})"
  end

  defp build_fetch_item(item, msg, full_msg, rfc822_cache, current_folder) do
    item_upper = String.upcase(String.trim(item))

    cond do
      item_upper == "UID" ->
        nil

      item_upper == "FLAGS" ->
        "FLAGS (#{format_flags(get_message_flags(msg, current_folder))})"

      item_upper == "INTERNALDATE" ->
        "INTERNALDATE \"#{format_internal_date(msg.inserted_at)}\""

      item_upper == "RFC822" ->
        literal_fetch_response("RFC822", rfc822_cache)

      item_upper == "RFC822.SIZE" ->
        "RFC822.SIZE #{byte_size(rfc822_cache || "")}"

      item_upper == "RFC822.HEADER" ->
        headers = build_full_headers(full_msg)
        literal_fetch_response("RFC822.HEADER", headers)

      item_upper == "RFC822.TEXT" ->
        text = build_body_text(full_msg)
        literal_fetch_response("RFC822.TEXT", text)

      item_upper == "ENVELOPE" ->
        "ENVELOPE #{build_envelope(full_msg || msg)}"

      item_upper == "BODYSTRUCTURE" ->
        "BODYSTRUCTURE #{build_bodystructure(full_msg)}"

      item_upper == "BODY" ->
        "BODY #{build_bodystructure(full_msg)}"

      item_upper == "PREVIEW" or item_upper == "PREVIEW (FUZZY)" ->
        preview = build_preview(full_msg)
        "PREVIEW \"#{preview}\""

      item_upper == "EMAILID" ->
        "EMAILID (#{msg.message_id || msg.id})"

      item_upper == "THREADID" ->
        "THREADID (T#{msg.id})"

      item_upper == "MODSEQ" ->
        "MODSEQ (1)"

      true ->
        build_body_fetch_item(item_upper, full_msg, rfc822_cache)
    end
  end

  defp fetch_item_needs_full_message?(item) do
    item_upper = String.upcase(String.trim(item))

    item_upper in [
      "RFC822",
      "RFC822.SIZE",
      "RFC822.HEADER",
      "RFC822.TEXT",
      "BODYSTRUCTURE",
      "BODY"
    ] or
      String.starts_with?(item_upper, "BODY[") or
      String.starts_with?(item_upper, "BODY.PEEK[") or
      item_upper in ["PREVIEW", "PREVIEW (FUZZY)"]
  end

  defp build_body_fetch_item(item_upper, full_msg, rfc822_cache) do
    case parse_body_item(item_upper) do
      {:ok, section, start_offset, length} ->
        build_body_section_response(section, start_offset, length, full_msg, rfc822_cache)

      :error ->
        nil
    end
  end

  defp parse_body_item(item_upper) do
    case Regex.run(~r/^BODY(?:\.PEEK)?\[([^\]]*)\](?:<(\d+)\.(\d+)>)?$/, item_upper) do
      [_, section, start_offset, length] ->
        {:ok, section, String.to_integer(start_offset), String.to_integer(length)}

      [_, section] ->
        {:ok, section, nil, nil}

      _ ->
        :error
    end
  end

  defp build_body_section_response("", start_offset, length, _full_msg, rfc822_cache) do
    {content, origin} = maybe_slice_literal(rfc822_cache || "", start_offset, length)
    literal_fetch_response("BODY[]", content, origin)
  end

  defp build_body_section_response("HEADER", start_offset, length, full_msg, _rfc822_cache) do
    headers = build_full_headers(full_msg)
    {content, origin} = maybe_slice_literal(headers, start_offset, length)
    literal_fetch_response("BODY[HEADER]", content, origin)
  end

  defp build_body_section_response("TEXT", start_offset, length, full_msg, _rfc822_cache) do
    text = build_body_text(full_msg)
    {content, origin} = maybe_slice_literal(text, start_offset, length)
    literal_fetch_response("BODY[TEXT]", content, origin)
  end

  defp build_body_section_response(section, start_offset, length, full_msg, _rfc822_cache) do
    cond do
      String.starts_with?(section, "HEADER.FIELDS.NOT") ->
        fields = parse_header_fields(section)
        headers = build_headers_excluding_fields(full_msg, fields)
        {content, origin} = maybe_slice_literal(headers, start_offset, length)
        fields_str = Enum.join(fields, " ")
        literal_fetch_response("BODY[HEADER.FIELDS.NOT (#{fields_str})]", content, origin)

      String.starts_with?(section, "HEADER.FIELDS") ->
        fields = parse_header_fields(section)
        headers = build_selected_headers(full_msg, fields)
        {content, origin} = maybe_slice_literal(headers, start_offset, length)
        fields_str = Enum.join(fields, " ")
        literal_fetch_response("BODY[HEADER.FIELDS (#{fields_str})]", content, origin)

      String.match?(section, ~r/^\d+(?:\.\d+)*\.MIME$/) ->
        mime_headers =
          "Content-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"

        {content, origin} = maybe_slice_literal(mime_headers, start_offset, length)
        literal_fetch_response("BODY[#{section}]", content, origin)

      String.match?(section, ~r/^\d+(?:\.\d+)*$/) ->
        part_content = extract_mime_part(full_msg, section)
        {content, origin} = maybe_slice_literal(part_content, start_offset, length)
        literal_fetch_response("BODY[#{section}]", content, origin)

      true ->
        nil
    end
  end

  defp maybe_slice_literal(content, nil, nil), do: {content, nil}

  defp maybe_slice_literal(content, start_offset, length)
       when is_integer(start_offset) and is_integer(length) do
    content_size = byte_size(content)

    if start_offset >= content_size do
      {"", start_offset}
    else
      slice_length = min(length, content_size - start_offset)
      {binary_part(content, start_offset, slice_length), start_offset}
    end
  end

  defp literal_fetch_response(name, content, origin \\ nil) do
    response_name = if is_integer(origin), do: "#{name}<#{origin}>", else: name
    "#{response_name} {#{byte_size(content)}}\r\n#{content}"
  end

  defp format_internal_date(datetime) do
    # Format: "DD-Mon-YYYY HH:MM:SS +0000"
    Calendar.strftime(datetime, "%d-%b-%Y %H:%M:%S +0000")
  end

  defp parse_header_fields(item) do
    case Regex.run(~r/\(([^)]*)\)/i, item) do
      [_, fields_str] ->
        String.split(fields_str)
        |> Enum.map(&String.upcase/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        ["DATE", "FROM", "TO", "CC", "BCC", "SUBJECT", "MESSAGE-ID"]
    end
  end

  defp build_selected_headers(msg, fields) do
    msg
    |> all_message_headers()
    |> Enum.filter(fn {name, value} ->
      String.upcase(name) in fields and present_header_value?(value)
    end)
    |> render_headers()
  end

  defp build_headers_excluding_fields(msg, excluded_fields) do
    msg
    |> all_message_headers()
    |> Enum.reject(fn {name, _value} ->
      String.upcase(name) in excluded_fields
    end)
    |> render_headers()
  end

  defp build_full_headers(msg) do
    msg
    |> all_message_headers()
    |> render_headers()
  end

  defp all_message_headers(msg) do
    [
      {"From", Map.get(msg, :from)},
      {"To", Map.get(msg, :to)},
      {"Cc", Map.get(msg, :cc)},
      {"Bcc", Map.get(msg, :bcc)},
      {"Subject", Map.get(msg, :subject)},
      {"Date", format_header_date(msg)},
      {"Message-ID", format_message_id_header(Map.get(msg, :message_id))},
      {"In-Reply-To", format_message_id_header(Map.get(msg, :in_reply_to))},
      {"References", Map.get(msg, :references)},
      {"MIME-Version", "1.0"},
      {"Content-Type", "text/plain; charset=\"UTF-8\""},
      {"Content-Transfer-Encoding", "8bit"}
    ]
  end

  defp render_headers(headers) do
    headers
    |> Enum.filter(fn {_name, value} -> present_header_value?(value) end)
    |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)
    |> Kernel.<>("\r\n")
  end

  defp present_header_value?(value), do: is_binary(value) and value != ""

  defp format_header_date(msg) do
    case Map.get(msg, :inserted_at) do
      %DateTime{} = inserted_at -> Helpers.format_date(inserted_at)
      _ -> nil
    end
  end

  defp format_message_id_header(nil), do: nil
  defp format_message_id_header(""), do: nil

  defp format_message_id_header(message_id) when is_binary(message_id) do
    trimmed = String.trim(message_id)

    if trimmed == "" do
      nil
    else
      if String.starts_with?(trimmed, "<") and String.ends_with?(trimmed, ">") do
        trimmed
      else
        "<#{trimmed}>"
      end
    end
  end

  defp build_body_text(msg) do
    Helpers.encode_as_8bit(msg.text_body || msg.html_body || "")
  end

  defp extract_mime_part(msg, _part_spec) do
    # For simple messages, part 1 is the text body
    # For multipart, we'd need to parse the structure
    # This is a simplified version
    msg.text_body || msg.html_body || ""
  end

  defp build_preview(msg) do
    # Build a ~200 char preview of the message
    text = msg.text_body || strip_html(msg.html_body) || ""

    text
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
    |> Helpers.escape_imap_string()
  end

  defp strip_html(html), do: Elektrine.TextHelpers.strip_html(html)

  defp load_and_decrypt_message(msg, user_id) do
    loaded_message =
      cond do
        match?(%Elektrine.Email.Message{}, msg) ->
          msg

        Map.has_key?(msg, :text_body) ->
          msg

        true ->
          Elektrine.Repo.get(Elektrine.Email.Message, msg.id)
      end

    case loaded_message do
      %Elektrine.Email.Message{} = message ->
        Elektrine.Email.Message.decrypt_content(message, user_id)

      map when is_map(map) ->
        map

      _ ->
        %{
          from: Map.get(msg, :from),
          to: Map.get(msg, :to),
          cc: Map.get(msg, :cc),
          bcc: Map.get(msg, :bcc),
          subject: Map.get(msg, :subject),
          message_id: Map.get(msg, :message_id),
          inserted_at: Map.get(msg, :inserted_at),
          text_body: "",
          html_body: ""
        }
    end
  end

  @doc "Build RFC822 format message"
  def build_rfc822_message(msg) do
    has_attachments = msg.has_attachments && msg.attachments && map_size(msg.attachments) > 0

    cond do
      has_attachments ->
        build_rfc822_with_attachments(msg)

      msg.text_body && msg.html_body ->
        boundary = Helpers.generate_boundary()

        """
        From: #{msg.from}\r
        To: #{msg.to}\r
        Subject: #{msg.subject}\r
        Date: #{Helpers.format_date(msg.inserted_at)}\r
        Message-ID: <#{msg.message_id}>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="#{boundary}"\r
        \r
        --#{boundary}\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.text_body)}\r
        \r
        --#{boundary}\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.html_body)}\r
        \r
        --#{boundary}--\r
        """

      msg.html_body ->
        """
        From: #{msg.from}\r
        To: #{msg.to}\r
        Subject: #{msg.subject}\r
        Date: #{Helpers.format_date(msg.inserted_at)}\r
        Message-ID: <#{msg.message_id}>\r
        MIME-Version: 1.0\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.html_body)}\r
        """

      true ->
        """
        From: #{msg.from}\r
        To: #{msg.to}\r
        Subject: #{msg.subject}\r
        Date: #{Helpers.format_date(msg.inserted_at)}\r
        Message-ID: <#{msg.message_id}>\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.text_body || "")}\r
        """
    end
  end

  defp build_rfc822_with_attachments(msg) do
    outer_boundary = Helpers.generate_boundary()
    parts = []

    body_part =
      if msg.text_body && msg.html_body do
        inner_boundary = Helpers.generate_boundary()

        """
        --#{outer_boundary}\r
        Content-Type: multipart/alternative; boundary="#{inner_boundary}"\r
        \r
        --#{inner_boundary}\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.text_body)}\r
        \r
        --#{inner_boundary}\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 8bit\r
        \r
        #{Helpers.encode_as_8bit(msg.html_body)}\r
        \r
        --#{inner_boundary}--\r
        """
      else
        if msg.html_body do
          """
          --#{outer_boundary}\r
          Content-Type: text/html; charset="UTF-8"\r
          Content-Transfer-Encoding: 8bit\r
          \r
          #{Helpers.encode_as_8bit(msg.html_body)}\r
          """
        else
          """
          --#{outer_boundary}\r
          Content-Type: text/plain; charset="UTF-8"\r
          Content-Transfer-Encoding: 8bit\r
          \r
          #{Helpers.encode_as_8bit(msg.text_body || "")}\r
          """
        end
      end

    parts = [body_part | parts]

    attachment_parts =
      Enum.map(msg.attachments, fn {_key, attachment} ->
        filename = attachment["filename"] || "attachment"
        content_type = attachment["content_type"] || "application/octet-stream"

        # Properly encode attachment data with line wrapping per RFC 2045
        data =
          case attachment do
            %{"storage_type" => storage_type} when storage_type in ["local", "s3"] ->
              case AttachmentStorage.download_attachment(attachment) do
                {:ok, content} -> Helpers.base64_encode_wrapped(content)
                {:error, _} -> attachment["data"] || ""
              end

            _ ->
              attachment["data"] || ""
          end

        content_id = attachment["content_id"]

        disposition =
          if content_id do
            "inline; filename=\"#{filename}\""
          else
            "attachment; filename=\"#{filename}\""
          end

        cid_header =
          if content_id do
            "Content-ID: <#{content_id}>\r\n"
          else
            ""
          end

        """
        --#{outer_boundary}\r
        Content-Type: #{content_type}; name="#{filename}"\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: #{disposition}\r
        #{cid_header}\r
        #{data}\r
        """
      end)

    parts = parts ++ attachment_parts

    """
    From: #{msg.from}\r
    To: #{msg.to}\r
    Subject: #{msg.subject}\r
    Date: #{Helpers.format_date(msg.inserted_at)}\r
    Message-ID: <#{msg.message_id}>\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="#{outer_boundary}"\r
    \r
    #{Enum.join(parts, "")}--#{outer_boundary}--\r
    """
  end

  @doc "Build ENVELOPE response"
  def build_envelope(msg) do
    date = Helpers.format_date(msg.inserted_at)
    subject = Helpers.escape_imap_string(msg.subject || "")
    from = parse_address(msg.from)
    # sender is same as from for our use case
    sender = from
    # reply-to defaults to from
    reply_to = from
    to = parse_address(msg.to)
    cc_value = Map.get(msg, :cc)
    cc = if cc_value && cc_value != "", do: parse_address(cc_value), else: "NIL"
    # BCC is not revealed
    bcc = "NIL"
    in_reply_to = envelope_message_id(Map.get(msg, :in_reply_to))
    message_id = envelope_message_id(msg.message_id)

    # ENVELOPE format: (date subject from sender reply-to to cc bcc in-reply-to message-id)
    "(\"#{date}\" \"#{subject}\" #{from} #{sender} #{reply_to} #{to} #{cc} #{bcc} #{in_reply_to} #{message_id})"
  end

  defp envelope_message_id(nil), do: "NIL"
  defp envelope_message_id(""), do: "NIL"

  defp envelope_message_id(value) when is_binary(value) do
    normalized =
      if String.starts_with?(value, "<") and String.ends_with?(value, ">"),
        do: value,
        else: "<#{value}>"

    "\"#{Helpers.escape_imap_string(normalized)}\""
  end

  @doc "Build BODYSTRUCTURE response"
  def build_bodystructure(msg) do
    has_attachments = msg.has_attachments && msg.attachments && map_size(msg.attachments) > 0

    if has_attachments do
      body_part =
        if msg.text_body && msg.html_body do
          text_lines = count_lines(msg.text_body)
          html_lines = count_lines(msg.html_body)
          # For TEXT types: ("TYPE" "SUBTYPE" (params) content-id description encoding size lines)
          text_part =
            "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.text_body)} #{text_lines})"

          html_part =
            "(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.html_body)} #{html_lines})"

          "(#{text_part} #{html_part} \"ALTERNATIVE\" (\"BOUNDARY\" \"alternative_boundary\") NIL NIL)"
        else
          if msg.html_body do
            html_lines = count_lines(msg.html_body)

            "(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.html_body)} #{html_lines})"
          else
            text_lines = count_lines(msg.text_body || "")

            "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.text_body || "")} #{text_lines})"
          end
        end

      attachment_parts =
        Enum.map(msg.attachments, fn {_key, attachment} ->
          filename = attachment["filename"] || "attachment"
          content_type = attachment["content_type"] || "application/octet-stream"
          size = attachment["size"] || byte_size(attachment["data"] || "")

          [type, subtype] =
            case String.split(content_type, "/", parts: 2) do
              [t, s] -> [String.upcase(t), String.upcase(s)]
              [t] -> [String.upcase(t), "OCTET-STREAM"]
            end

          disposition = if attachment["content_id"], do: "INLINE", else: "ATTACHMENT"

          # Non-text parts don't need line count
          "(\"#{type}\" \"#{subtype}\" (\"NAME\" \"#{filename}\") NIL NIL \"BASE64\" #{size} NIL (\"#{disposition}\" (\"FILENAME\" \"#{filename}\")) NIL NIL)"
        end)

      all_parts = [body_part | attachment_parts] |> Enum.join(" ")
      "(#{all_parts} \"MIXED\" (\"BOUNDARY\" \"mixed_boundary\") NIL NIL)"
    else
      if msg.html_body do
        html_lines = count_lines(msg.html_body || "")

        "(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.html_body || "")} #{html_lines})"
      else
        text_lines = count_lines(msg.text_body || "")

        "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" #{byte_size(msg.text_body || "")} #{text_lines})"
      end
    end
  end

  defp count_lines(nil), do: 0
  defp count_lines(""), do: 0

  defp count_lines(text) do
    # Count newlines + 1 for last line
    String.split(text, ~r/\r?\n/) |> length()
  end

  @doc "Build message headers for FETCH response"
  def build_message_headers(msg) do
    """
    From: #{msg.from}\r
    To: #{msg.to}\r
    Subject: #{msg.subject}\r
    Date: #{Helpers.format_date(msg.inserted_at)}\r
    Message-ID: <#{msg.message_id}>\r
    \r
    """
  end

  @doc "Parse email address for IMAP format"
  def parse_address(nil), do: "NIL"
  def parse_address(""), do: "NIL"

  def parse_address(email) when is_binary(email) do
    # Handle multiple addresses separated by comma
    addresses =
      email
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map_join(" ", &parse_single_address/1)

    "(#{addresses})"
  end

  defp parse_single_address(addr) do
    # Try to parse "Display Name <email@example.com>" format
    case Regex.run(~r/^"?([^"<]*)"?\s*<([^>]+)>$/, String.trim(addr)) do
      [_, display_name, email_part] ->
        display_name = String.trim(display_name)

        case String.split(email_part, "@") do
          [local, domain] ->
            name =
              if display_name != "",
                do: "\"#{Helpers.escape_imap_string(display_name)}\"",
                else: "NIL"

            "(#{name} NIL \"#{local}\" \"#{domain}\")"

          _ ->
            "(NIL NIL \"#{email_part}\" NIL)"
        end

      _ ->
        # Plain email address
        case String.split(addr, "@") do
          [local, domain] ->
            "(NIL NIL \"#{local}\" \"#{domain}\")"

          _ ->
            "(NIL NIL \"#{addr}\" NIL)"
        end
    end
  end

  @doc "Get message flags"
  def get_message_flags(msg, current_folder) do
    flags = []
    flags = if msg.read, do: ["\\Seen" | flags], else: flags
    flags = if msg.flagged, do: ["\\Flagged" | flags], else: flags
    flags = if Map.get(msg, :answered, false), do: ["\\Answered" | flags], else: flags
    flags = if Map.get(msg, :status) == "draft", do: ["\\Draft" | flags], else: flags

    flags =
      if Map.get(msg, :deleted, false) && String.upcase(current_folder || "") != "TRASH" do
        ["\\Deleted" | flags]
      else
        flags
      end

    flags = if Map.get(msg, :spam, false), do: ["Junk" | flags], else: ["NonJunk" | flags]
    flags
  end

  @doc "Format flags for IMAP response"
  def format_flags(flags) do
    Enum.join(flags, " ")
  end

  @doc "Apply flag operation (FLAGS, +FLAGS, -FLAGS)"
  def apply_flag_operation(msg, operation, flags, current_folder) do
    current_flags = get_message_flags(msg, current_folder)
    normalized_operation = operation |> String.upcase() |> String.replace_suffix(".SILENT", "")

    case normalized_operation do
      "FLAGS" -> flags
      "+FLAGS" -> Enum.uniq(current_flags ++ flags)
      "-FLAGS" -> current_flags -- flags
      _ -> current_flags
    end
  end
end
