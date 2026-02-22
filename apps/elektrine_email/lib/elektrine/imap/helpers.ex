defmodule Elektrine.IMAP.Helpers do
  @moduledoc "Helper functions for IMAP server operations including parsing, validation,\npattern matching, and utility functions.\n"
  require Logger
  @doc "Parse LOGIN command arguments"
  def parse_login_args(nil) do
    {:error, :missing_args}
  end

  def parse_login_args(args) do
    case parse_quoted_strings(args) do
      [username, password] ->
        {:ok, username, password}

      _ ->
        case String.split(args, " ", parts: 2) do
          [username, password] -> {:ok, username, password}
          _ -> {:error, :invalid_format}
        end
    end
  end

  defp parse_quoted_strings(str) do
    Regex.scan(~r/"([^"\\]*(?:\\.[^"\\]*)*)"|(\S+)/, str)
    |> Enum.map(fn
      [_, quoted, ""] -> quoted
      [_, "", unquoted] -> unquoted
      [_, quoted] -> quoted
      [unquoted] -> unquoted
    end)
  end

  @doc "Parse LIST command arguments"
  def parse_list_args(nil) do
    {"", "*"}
  end

  def parse_list_args(args) do
    case String.split(args, " ", parts: 2) do
      [reference, pattern] ->
        reference = String.trim(reference, "\"")
        pattern = String.trim(pattern, "\"")
        {reference, pattern}

      [pattern] ->
        pattern = String.trim(pattern, "\"")
        {"", pattern}

      _ ->
        {"", "*"}
    end
  end

  @doc "Parse STATUS command arguments"
  def parse_status_args(nil) do
    {:error, :missing_args}
  end

  def parse_status_args(args) do
    case Regex.run(~r/"([^"]+)"\s*\(([^)]+)\)/, args) do
      [_, folder, items] -> {:ok, folder, String.split(items, " ")}
      _ -> {:error, :invalid_format}
    end
  end

  @doc "Parse FETCH command arguments"
  def parse_fetch_args(nil) do
    {:error, :missing_args}
  end

  def parse_fetch_args(args) do
    trimmed = String.trim(args)

    case Regex.run(~r/^([^\s]+)\s+(.+)$/, trimmed) do
      [_, sequence_set, items_str] ->
        items = parse_fetch_items(items_str)
        {:ok, sequence_set, items}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Parse fetch items list"
  def parse_fetch_items(items_str) do
    cleaned = items_str |> String.trim() |> String.trim_leading("(") |> String.trim_trailing(")")

    if String.contains?(cleaned, "[") do
      parse_complex_items(cleaned)
    else
      String.split(cleaned, ~r/\s+/) |> Enum.reject(&(&1 == ""))
    end
  end

  defp parse_complex_items(str) do
    simple_items = ["UID", "FLAGS", "RFC822.SIZE", "ENVELOPE", "BODYSTRUCTURE"]
    words = String.split(str, ~r/\s+/)

    Enum.filter(words, fn word ->
      String.upcase(word) in simple_items or String.starts_with?(word, "BODY")
    end)
  end

  @doc "Parse COPY/MOVE command arguments"
  def parse_copy_args(nil) do
    {:error, :missing_args}
  end

  def parse_copy_args(args) do
    case String.split(args, " ", parts: 2) do
      [uid_set, folder] ->
        folder = String.trim(folder, "\"")
        {:ok, uid_set, folder}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Parse STORE command arguments"
  def parse_store_args(nil) do
    {:error, :missing_args}
  end

  def parse_store_args(args) do
    case String.split(args, " ", parts: 3) do
      [sequence_set, operation, flags_str] ->
        flags =
          flags_str
          |> String.trim()
          |> String.trim_leading("(")
          |> String.trim_trailing(")")
          |> String.split(~r/\s+/)
          |> Enum.reject(&(&1 == ""))

        {:ok, sequence_set, operation, flags}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Parse APPEND command arguments"
  def parse_append_args(args) do
    case Regex.run(~r/"([^"]+)"\s*(?:\([^)]*\))?\s*\{(\d+)\+?\}/, args || "") do
      [_, folder, size_str] ->
        case Integer.parse(size_str) do
          {size, ""} ->
            is_literal_plus = String.contains?(args || "", "+}")
            {:ok, folder, [], size, is_literal_plus}

          _ ->
            {:error, :invalid_size}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Decode PLAIN authentication credentials"
  def decode_auth_plain(credentials) do
    decoded = Base.decode64!(credentials)

    case String.split(decoded, "\0") do
      ["", username, password] -> {:ok, username, password}
      [_authzid, username, password] -> {:ok, username, password}
      _ -> {:error, :invalid_format}
    end
  rescue
    _ -> {:error, :decode_failed}
  end

  @doc "Parse sequence number with wildcard support"
  def parse_sequence_number("*", max) when is_integer(max) and max > 0 do
    max
  end

  def parse_sequence_number("*", _max) do
    nil
  end

  def parse_sequence_number(str, _max) do
    case Integer.parse(str) do
      {num, ""} when num > 0 -> num
      _ -> nil
    end
  end

  @doc "Parse UID number with wildcard support"
  def parse_uid_number("*", messages) do
    if messages == [] do
      0
    else
      Enum.max_by(messages, & &1.id).id
    end
  end

  def parse_uid_number(str, _messages) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> 0
    end
  end

  @doc "Get messages by sequence number"
  def get_messages_by_sequence(messages, sequence_set) do
    max_sequence = length(messages)

    sequence_set
    |> String.split(",", trim: true)
    |> Enum.flat_map(&expand_sequence_part(&1, max_sequence))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn sequence_number ->
      case Enum.at(messages, sequence_number - 1) do
        nil -> []
        message -> [{message, sequence_number}]
      end
    end)
  end

  defp expand_sequence_part(sequence_part, max_sequence) do
    part = String.trim(sequence_part)

    sequence_numbers =
      case String.split(part, ":") do
        [start_str, end_str] ->
          with start_num when is_integer(start_num) <-
                 parse_sequence_number(start_str, max_sequence),
               end_num when is_integer(end_num) <- parse_sequence_number(end_str, max_sequence) do
            lower = min(start_num, end_num)
            upper = max(start_num, end_num)
            Enum.to_list(lower..upper)
          else
            _ -> []
          end

        [single] ->
          case parse_sequence_number(single, max_sequence) do
            num when is_integer(num) -> [num]
            _ -> []
          end

        _ ->
          []
      end

    Enum.filter(sequence_numbers, fn num -> num >= 1 and num <= max_sequence end)
  end

  @doc "Get messages by UID"
  def get_messages_by_uid(messages, uid_set) do
    uid_parts = String.split(uid_set, ",")

    results =
      Enum.flat_map(uid_parts, fn part ->
        case String.trim(part) do
          "*" ->
            messages |> Enum.with_index(1)

          part_str ->
            case String.split(part_str, ":") do
              [start_str, end_str] ->
                start_uid = parse_uid_number(start_str, messages)
                end_uid = parse_uid_number(end_str, messages)

                messages
                |> Enum.with_index(1)
                |> Enum.filter(fn {msg, _idx} -> msg.id >= start_uid and msg.id <= end_uid end)

              [uid_str] ->
                case Integer.parse(uid_str) do
                  {uid, ""} ->
                    messages
                    |> Enum.with_index(1)
                    |> Enum.filter(fn {msg, _idx} -> msg.id == uid end)

                  _ ->
                    []
                end

              _ ->
                []
            end
        end
      end)
      |> Enum.uniq_by(fn {msg, _} -> msg.id end)

    results
  end

  @doc "Check if UID matches UID set specification"
  def matches_uid_in_set?(uid, uid_set) do
    uid_parts = String.split(uid_set, ",")

    Enum.any?(uid_parts, fn part ->
      case String.split(String.trim(part), ":") do
        [start_str, end_str] ->
          case {Integer.parse(start_str), Integer.parse(end_str)} do
            {{start_uid, ""}, {end_uid, ""}} -> uid >= start_uid and uid <= end_uid
            _ -> false
          end

        [uid_str] ->
          case Integer.parse(uid_str) do
            {target_uid, ""} -> uid == target_uid
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  @doc "Check if message matches search criteria"
  def matches_search_criteria?(msg, criteria, sequence_number \\ nil, max_sequence \\ nil) do
    criteria_upper = String.upcase(criteria)

    cond do
      criteria_upper == "ALL" ->
        true

      criteria_upper == "UNSEEN" ->
        !msg.read

      criteria_upper == "SEEN" ->
        msg.read

      criteria_upper == "FLAGGED" ->
        msg.flagged

      criteria_upper == "UNFLAGGED" ->
        !msg.flagged

      criteria_upper == "DELETED" ->
        Map.get(msg, :deleted, false)

      criteria_upper == "UNDELETED" ->
        !Map.get(msg, :deleted, false)

      criteria_upper == "NEW" ->
        !msg.read

      criteria_upper == "OLD" ->
        msg.read

      criteria_upper == "RECENT" ->
        !msg.read

      criteria_upper == "ANSWERED" ->
        Map.get(msg, :answered, false)

      criteria_upper == "UNANSWERED" ->
        !Map.get(msg, :answered, false)

      criteria_upper == "DRAFT" ->
        Map.get(msg, :status) == "draft"

      criteria_upper == "UNDRAFT" ->
        Map.get(msg, :status) != "draft"

      String.starts_with?(criteria_upper, "UID ") ->
        matches_uid_range?(msg, String.replace_prefix(criteria_upper, "UID ", ""))

      String.starts_with?(criteria_upper, "FROM ") ->
        matches_from?(msg, String.slice(criteria, 5..-1//1))

      String.starts_with?(criteria_upper, "TO ") ->
        matches_to?(msg, String.slice(criteria, 3..-1//1))

      String.starts_with?(criteria_upper, "CC ") ->
        matches_cc?(msg, String.slice(criteria, 3..-1//1))

      String.starts_with?(criteria_upper, "BCC ") ->
        matches_bcc?(msg, String.slice(criteria, 4..-1//1))

      String.starts_with?(criteria_upper, "SUBJECT ") ->
        matches_subject?(msg, String.slice(criteria, 8..-1//1))

      String.starts_with?(criteria_upper, "BODY ") ->
        matches_body?(msg, String.slice(criteria, 5..-1//1))

      String.starts_with?(criteria_upper, "TEXT ") ->
        matches_text?(msg, String.slice(criteria, 5..-1//1))

      String.starts_with?(criteria_upper, "HEADER ") ->
        matches_header?(msg, String.slice(criteria, 7..-1//1))

      String.starts_with?(criteria_upper, "BEFORE ") ->
        matches_before?(msg, String.slice(criteria, 7..-1//1))

      String.starts_with?(criteria_upper, "ON ") ->
        matches_on?(msg, String.slice(criteria, 3..-1//1))

      String.starts_with?(criteria_upper, "SINCE ") ->
        matches_since?(msg, String.slice(criteria, 6..-1//1))

      String.starts_with?(criteria_upper, "SENTBEFORE ") ->
        matches_before?(msg, String.slice(criteria, 11..-1//1))

      String.starts_with?(criteria_upper, "SENTON ") ->
        matches_on?(msg, String.slice(criteria, 7..-1//1))

      String.starts_with?(criteria_upper, "SENTSINCE ") ->
        matches_since?(msg, String.slice(criteria, 10..-1//1))

      String.starts_with?(criteria_upper, "LARGER ") ->
        matches_larger?(msg, String.slice(criteria, 7..-1//1))

      String.starts_with?(criteria_upper, "SMALLER ") ->
        matches_smaller?(msg, String.slice(criteria, 8..-1//1))

      String.starts_with?(criteria_upper, "NOT ") ->
        !matches_search_criteria?(
          msg,
          String.slice(criteria, 4..-1//1),
          sequence_number,
          max_sequence
        )

      String.match?(criteria, ~r/^[\d\*]+(:[\d\*]+)?(,[\d\*]+(:[\d\*]+)?)*$/) ->
        matches_sequence_set?(sequence_number, max_sequence, criteria)

      true ->
        true
    end
  end

  defp matches_uid_range?(msg, range) do
    case String.split(range, ":") do
      [start_str, end_str] ->
        with {start_uid, _} <- Integer.parse(start_str),
             {end_uid, _} <- Integer.parse(end_str) do
          msg.id >= start_uid and msg.id <= end_uid
        else
          _ -> false
        end

      [uid_str] ->
        case Integer.parse(uid_str) do
          {uid, _} -> msg.id == uid
          _ -> false
        end

      _ ->
        false
    end
  end

  defp matches_from?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    String.contains?(String.downcase(msg.from || ""), String.downcase(search_term))
  end

  defp matches_to?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    String.contains?(String.downcase(msg.to || ""), String.downcase(search_term))
  end

  defp matches_subject?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    String.contains?(String.downcase(msg.subject || ""), String.downcase(search_term))
  end

  defp matches_body?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    text_body = Map.get(msg, :text_body) || ""
    String.contains?(String.downcase(text_body), String.downcase(search_term))
  end

  defp matches_text?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    subject = Map.get(msg, :subject) || ""
    text_body = Map.get(msg, :text_body) || ""
    text = "#{subject} #{text_body}"
    String.contains?(String.downcase(text), String.downcase(search_term))
  end

  defp matches_cc?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    String.contains?(String.downcase(msg.cc || ""), String.downcase(search_term))
  end

  defp matches_bcc?(msg, search_term) do
    search_term = String.trim(search_term, "\"")
    String.contains?(String.downcase(msg.bcc || ""), String.downcase(search_term))
  end

  defp matches_header?(msg, args) do
    case String.split(args, " ", parts: 2) do
      [field_name, search_term] ->
        search_term = String.trim(search_term, "\"")

        field_value =
          case String.upcase(field_name) do
            "FROM" -> msg.from
            "TO" -> msg.to
            "CC" -> msg.cc
            "BCC" -> msg.bcc
            "SUBJECT" -> msg.subject
            "MESSAGE-ID" -> msg.message_id
            _ -> ""
          end

        String.contains?(String.downcase(field_value || ""), String.downcase(search_term))

      _ ->
        false
    end
  end

  defp matches_before?(msg, date_str) do
    date_str = String.trim(date_str)

    case parse_imap_date(date_str) do
      {:ok, date} -> DateTime.compare(msg.inserted_at, date) == :lt
      _ -> false
    end
  end

  defp matches_on?(msg, date_str) do
    date_str = String.trim(date_str)

    case parse_imap_date(date_str) do
      {:ok, date} ->
        msg_date = DateTime.to_date(msg.inserted_at)
        target_date = DateTime.to_date(date)
        Date.compare(msg_date, target_date) == :eq

      _ ->
        false
    end
  end

  defp matches_since?(msg, date_str) do
    date_str = String.trim(date_str)

    case parse_imap_date(date_str) do
      {:ok, date} -> DateTime.compare(msg.inserted_at, date) in [:gt, :eq]
      _ -> false
    end
  end

  defp matches_larger?(msg, size_str) do
    case Integer.parse(String.trim(size_str)) do
      {size, _} ->
        text_body = Map.get(msg, :text_body) || ""
        byte_size(text_body) > size

      _ ->
        false
    end
  end

  defp matches_smaller?(msg, size_str) do
    case Integer.parse(String.trim(size_str)) do
      {size, _} ->
        text_body = Map.get(msg, :text_body) || ""
        byte_size(text_body) < size

      _ ->
        false
    end
  end

  defp matches_sequence_set?(nil, _max_sequence, _set) do
    false
  end

  defp matches_sequence_set?(_sequence_number, nil, _set) do
    false
  end

  defp matches_sequence_set?(sequence_number, max_sequence, set)
       when is_integer(sequence_number) and is_integer(max_sequence) do
    set
    |> String.split(",", trim: true)
    |> Enum.any?(fn part ->
      matches_sequence_set_part?(sequence_number, max_sequence, String.trim(part))
    end)
  end

  defp matches_sequence_set_part?(sequence_number, max_sequence, part) do
    case String.split(part, ":") do
      [start_str, end_str] ->
        with start_num when is_integer(start_num) <-
               parse_sequence_number(start_str, max_sequence),
             end_num when is_integer(end_num) <- parse_sequence_number(end_str, max_sequence) do
          lower = min(start_num, end_num)
          upper = max(start_num, end_num)
          sequence_number >= lower and sequence_number <= upper
        else
          _ -> false
        end

      [single] ->
        case parse_sequence_number(single, max_sequence) do
          num when is_integer(num) -> sequence_number == num
          _ -> false
        end

      _ ->
        false
    end
  end

  defp parse_imap_date(date_str) do
    date_str = String.trim(date_str, "\"")

    case Regex.run(~r/(\d{1,2})-(\w{3})-(\d{4})/, date_str) do
      [_, day, month, year] ->
        month_num = month_to_number(month)

        case Date.new(String.to_integer(year), month_num, String.to_integer(day)) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp month_to_number(month) do
    case String.upcase(month) do
      "JAN" -> 1
      "FEB" -> 2
      "MAR" -> 3
      "APR" -> 4
      "MAY" -> 5
      "JUN" -> 6
      "JUL" -> 7
      "AUG" -> 8
      "SEP" -> 9
      "OCT" -> 10
      "NOV" -> 11
      "DEC" -> 12
      _ -> 1
    end
  end

  @doc "Check if folder name matches pattern"
  def matches_pattern?(name, pattern) do
    cond do
      pattern == "*" or pattern == "%" ->
        true

      String.contains?(pattern, "*") ->
        pattern_parts = String.split(pattern, "*", trim: false)
        matches_wildcard_pattern?(String.downcase(name), pattern_parts)

      String.contains?(pattern, "%") ->
        pattern_parts = String.split(pattern, "%", trim: false)
        matches_wildcard_pattern?(String.downcase(name), pattern_parts)

      true ->
        String.downcase(name) == String.downcase(pattern)
    end
  end

  defp matches_wildcard_pattern?(name, [single_part]) do
    name == String.downcase(single_part)
  end

  defp matches_wildcard_pattern?(name, parts) when is_list(parts) do
    [first | rest] = parts
    last = List.last(rest)
    middle = Enum.slice(rest, 0..-2//1)

    starts_ok =
      if first == "" do
        true
      else
        String.starts_with?(name, String.downcase(first))
      end

    ends_ok =
      if last == "" do
        true
      else
        String.ends_with?(name, String.downcase(last))
      end

    middle_ok =
      Enum.reduce_while(middle, String.slice(name, String.length(first)..-1//1), fn part,
                                                                                    remaining ->
        if part == "" do
          {:cont, remaining}
        else
          case :binary.match(remaining, String.downcase(part)) do
            {pos, len} -> {:cont, String.slice(remaining, (pos + len)..-1//1)}
            :nomatch -> {:halt, :nomatch}
          end
        end
      end)

    starts_ok and ends_ok and middle_ok != :nomatch
  end

  @doc "Check if message should be in current folder"
  def message_in_current_folder?(message, folder) do
    folder_normalized = String.upcase(folder)

    case folder_normalized do
      "INBOX" ->
        message.status not in ["sent", "draft"] and not message.spam and not message.deleted and
          not message.archived

      "SENT" ->
        message.status == "sent" and not message.deleted

      "DRAFTS" ->
        message.status == "draft" and not message.deleted

      "TRASH" ->
        message.deleted

      "SPAM" ->
        message.spam and message.status not in ["sent", "draft"] and not message.deleted

      _ ->
        false
    end
  end

  @doc "Get next available UID for mailbox"
  def get_next_uid(messages) do
    if messages == [] do
      1
    else
      Enum.max_by(messages, & &1.id).id + 1
    end
  end

  @doc "Count unseen messages"
  def count_unseen(messages) do
    Enum.count(messages, fn msg -> !msg.read end)
  end

  @doc "Check if FETCH items should mark messages as read"
  def should_mark_as_read?(items) do
    Enum.any?(items, fn item ->
      item_upper = String.upcase(item)

      (String.starts_with?(item_upper, "BODY[") && !String.contains?(item_upper, "PEEK")) ||
        item_upper == "RFC822" || item_upper == "RFC822.TEXT"
    end)
  end

  @doc "Generate random boundary for MIME messages"
  def generate_boundary do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc "Generate unique session ID"
  def generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc "Format date for IMAP response (RFC 5322 compliant)"
  def format_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  @doc "Escape string for IMAP protocol"
  def escape_imap_string(str) when is_binary(str) do
    str |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  def escape_imap_string(_) do
    ""
  end

  @doc "Redact email addresses in logs"
  def redact_email(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] ->
        redacted_local = String.slice(local, 0..1) <> "***"
        "#{redacted_local}@#{domain}"

      _ ->
        "***"
    end
  end

  def redact_email(_) do
    "***"
  end

  @doc "Normalize IPv6 addresses to /64 subnet"
  def normalize_ipv6_subnet(ip_string) do
    if String.contains?(ip_string, ":") do
      hextets = String.split(ip_string, ":")

      if Enum.any?(hextets, &(&1 == "")) do
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after
        Enum.take(expanded, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      else
        Enum.take(hextets, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      end
    else
      ip_string
    end
  end

  @doc "Encode text as quoted-printable per RFC 2045.\nFor simplicity, we use 8bit transfer encoding for UTF-8 content since\nmodern email clients support it and it's more readable.\n"
  def encode_as_8bit(content) when is_binary(content) do
    content |> String.replace(~r/\r?\n/, "\r\n")
  end

  def encode_as_8bit(nil) do
    ""
  end

  @doc "Encode binary data as base64 with proper line wrapping at 76 characters per RFC 2045.\n"
  def base64_encode_wrapped(data) when is_binary(data) do
    data |> Base.encode64() |> wrap_lines(76)
  end

  def base64_encode_wrapped(nil) do
    ""
  end

  defp wrap_lines(text, max_length) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(max_length)
    |> Enum.map_join("\r\n", &Enum.join/1)
  end

  @doc "Send response to IMAP client"
  def send_response(socket, message) do
    :gen_tcp.send(socket, "#{message}\r\n")
  end
end
