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
    parts =
      (["UID #{msg.id}"] ++
         Enum.map(items, fn item ->
           item_upper = String.upcase(item)

           cond do
             item_upper == "UID" ->
               nil

             item_upper == "FLAGS" ->
               "FLAGS (#{format_flags(get_message_flags(msg, current_folder))})"

             item_upper == "INTERNALDATE" ->
               "INTERNALDATE \"#{format_internal_date(msg.inserted_at)}\""

             # Full message - various formats
             item_upper == "BODY[]" or item_upper == "BODY.PEEK[]" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               rfc822 = build_rfc822_message(full_msg)
               "BODY[] {#{byte_size(rfc822)}}\r\n#{rfc822}"

             item_upper == "RFC822" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               rfc822 = build_rfc822_message(full_msg)
               "RFC822 {#{byte_size(rfc822)}}\r\n#{rfc822}"

             item_upper == "RFC822.SIZE" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               "RFC822.SIZE #{byte_size(build_rfc822_message(full_msg))}"

             # Header only
             item_upper == "RFC822.HEADER" or item_upper == "BODY[HEADER]" or
                 item_upper == "BODY.PEEK[HEADER]" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               headers = build_full_headers(full_msg)

               response_name =
                 if item_upper == "RFC822.HEADER", do: "RFC822.HEADER", else: "BODY[HEADER]"

               "#{response_name} {#{byte_size(headers)}}\r\n#{headers}"

             # Text body only
             item_upper == "RFC822.TEXT" or item_upper == "BODY[TEXT]" or
                 item_upper == "BODY.PEEK[TEXT]" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               text = build_body_text(full_msg)

               response_name =
                 if item_upper == "RFC822.TEXT", do: "RFC822.TEXT", else: "BODY[TEXT]"

               "#{response_name} {#{byte_size(text)}}\r\n#{text}"

             # Specific MIME part - BODY[1], BODY[1.1], etc.
             String.match?(item_upper, ~r/^BODY\.?PEEK?\[(\d+(?:\.\d+)*)\]$/) ->
               full_msg = load_and_decrypt_message(msg, user_id)
               part_content = extract_mime_part(full_msg, item_upper)
               part_spec = Regex.run(~r/\[([^\]]+)\]/, item_upper) |> List.last()
               "BODY[#{part_spec}] {#{byte_size(part_content)}}\r\n#{part_content}"

             # MIME part headers - BODY[1.MIME]
             String.match?(item_upper, ~r/^BODY\.?PEEK?\[(\d+(?:\.\d+)*)\.MIME\]$/) ->
               part_spec = Regex.run(~r/\[([^\]]+)\]/, item_upper) |> List.last()

               mime_headers =
                 "Content-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"

               "BODY[#{part_spec}] {#{byte_size(mime_headers)}}\r\n#{mime_headers}"

             item_upper == "ENVELOPE" ->
               "ENVELOPE #{build_envelope(msg)}"

             item_upper == "BODYSTRUCTURE" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               "BODYSTRUCTURE #{build_bodystructure(full_msg)}"

             item_upper == "BODY" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               "BODY #{build_bodystructure(full_msg)}"

             # Header fields - BODY[HEADER.FIELDS (field1 field2)]
             String.starts_with?(item_upper, "BODY.PEEK[HEADER.FIELDS") or
                 String.starts_with?(item_upper, "BODY[HEADER.FIELDS") ->
               full_msg = load_and_decrypt_message(msg, user_id)
               fields = parse_header_fields(item_upper)
               headers = build_selected_headers(full_msg, fields)
               fields_str = Enum.join(fields, " ")
               "BODY[HEADER.FIELDS (#{fields_str})] {#{byte_size(headers)}}\r\n#{headers}"

             # Header fields NOT - exclude certain fields
             String.starts_with?(item_upper, "BODY[HEADER.FIELDS.NOT") ->
               full_msg = load_and_decrypt_message(msg, user_id)
               headers = build_full_headers(full_msg)
               "BODY[HEADER.FIELDS.NOT ()] {#{byte_size(headers)}}\r\n#{headers}"

             # PREVIEW - message preview/snippet (RFC 8970)
             item_upper == "PREVIEW" or item_upper == "PREVIEW (FUZZY)" ->
               full_msg = load_and_decrypt_message(msg, user_id)
               preview = build_preview(full_msg)
               "PREVIEW \"#{preview}\""

             # EMAILID and THREADID for OBJECTID extension
             item_upper == "EMAILID" ->
               "EMAILID (#{msg.message_id || msg.id})"

             item_upper == "THREADID" ->
               "THREADID (T#{msg.id})"

             # MODSEQ for CONDSTORE
             item_upper == "MODSEQ" ->
               "MODSEQ (1)"

             true ->
               nil
           end
         end))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    "* #{seq_num} FETCH (#{parts})"
  end

  defp format_internal_date(datetime) do
    # Format: "DD-Mon-YYYY HH:MM:SS +0000"
    Calendar.strftime(datetime, "%d-%b-%Y %H:%M:%S +0000")
  end

  defp parse_header_fields(item) do
    case Regex.run(~r/\(([^)]+)\)/i, item) do
      [_, fields_str] ->
        String.split(fields_str)
        |> Enum.map(&String.upcase/1)

      _ ->
        ["FROM", "TO", "CC", "BCC", "SUBJECT", "DATE", "MESSAGE-ID"]
    end
  end

  defp build_selected_headers(msg, fields) do
    all_headers = [
      {"FROM", msg.from},
      {"TO", msg.to},
      {"CC", msg.cc},
      {"BCC", msg.bcc},
      {"SUBJECT", msg.subject},
      {"DATE", Helpers.format_date(msg.inserted_at)},
      {"MESSAGE-ID", "<#{msg.message_id}>"},
      {"CONTENT-TYPE", "text/plain; charset=\"UTF-8\""},
      {"MIME-VERSION", "1.0"}
    ]

    selected =
      Enum.filter(all_headers, fn {name, value} ->
        String.upcase(name) in fields && value && value != ""
      end)

    header_lines =
      Enum.map(selected, fn {name, value} ->
        "#{name}: #{value}\r\n"
      end)

    Enum.join(header_lines) <> "\r\n"
  end

  defp build_full_headers(msg) do
    """
    From: #{msg.from}\r
    To: #{msg.to}\r
    #{if msg.cc && msg.cc != "", do: "Cc: #{msg.cc}\r\n", else: ""}Subject: #{msg.subject}\r
    Date: #{Helpers.format_date(msg.inserted_at)}\r
    Message-ID: <#{msg.message_id}>\r
    MIME-Version: 1.0\r
    Content-Type: text/plain; charset="UTF-8"\r
    Content-Transfer-Encoding: 8bit\r
    \r
    """
  end

  defp build_body_text(msg) do
    Helpers.encode_as_8bit(msg.text_body || msg.html_body || "")
  end

  defp extract_mime_part(msg, _item) do
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
    if Map.has_key?(msg, :text_body) do
      msg
    else
      Elektrine.Repo.get(Elektrine.Email.Message, msg.id)
    end
    |> Elektrine.Email.Message.decrypt_content(user_id)
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
            %{"storage_type" => "s3"} ->
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
    in_reply_to = "NIL"
    message_id = if msg.message_id, do: "\"<#{msg.message_id}>\"", else: "NIL"

    # ENVELOPE format: (date subject from sender reply-to to cc bcc in-reply-to message-id)
    "(\"#{date}\" \"#{subject}\" #{from} #{sender} #{reply_to} #{to} #{cc} #{bcc} #{in_reply_to} #{message_id})"
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
