defmodule Elektrine.Calendar.ICalendar do
  @moduledoc """
  iCalendar (RFC 5545) parser and generator for CalDAV support.
  Handles VEVENT, VTODO, and VALARM components.
  """

  @doc """
  Parse an iCalendar string into an event map.
  """
  def parse(icalendar_string) when is_binary(icalendar_string) do
    # Unfold continuation lines
    unfolded = unfold_lines(icalendar_string)

    lines =
      String.split(unfolded, ~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Find VEVENT block
    case extract_vevent(lines) do
      {:ok, event_lines} ->
        event = parse_event_lines(event_lines)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Generate an iCalendar string from an event struct or map.
  """
  def generate(event) when is_map(event) do
    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Elektrine//CalDAV Server//EN",
      "CALSCALE:GREGORIAN"
    ]

    # Add timezone if present
    tz = Map.get(event, :timezone) || Map.get(event, "timezone")

    lines =
      if tz && tz != "UTC" do
        lines ++ build_vtimezone(tz)
      else
        lines
      end

    # Add VEVENT
    lines = lines ++ ["BEGIN:VEVENT"]

    # Required properties
    uid = Map.get(event, :uid) || Map.get(event, "uid") || generate_uid()
    dtstart = Map.get(event, :dtstart) || Map.get(event, "dtstart")
    dtstamp = DateTime.utc_now()

    lines =
      lines ++
        [
          "UID:#{uid}",
          "DTSTAMP:#{format_datetime(dtstamp)}"
        ]

    # Start time
    all_day = Map.get(event, :all_day, false) || Map.get(event, "all_day", false)
    lines = lines ++ [format_dtstart(dtstart, all_day, tz)]

    # End time or duration
    dtend = Map.get(event, :dtend) || Map.get(event, "dtend")
    duration = Map.get(event, :duration) || Map.get(event, "duration")

    lines =
      cond do
        dtend -> lines ++ [format_dtend(dtend, all_day, tz)]
        duration -> lines ++ ["DURATION:#{duration}"]
        true -> lines
      end

    # Summary (title)
    summary = Map.get(event, :summary) || Map.get(event, "summary")
    lines = if summary, do: lines ++ ["SUMMARY:#{escape_value(summary)}"], else: lines

    # Description
    description = Map.get(event, :description) || Map.get(event, "description")
    lines = if description, do: lines ++ ["DESCRIPTION:#{escape_value(description)}"], else: lines

    # Location
    location = Map.get(event, :location) || Map.get(event, "location")
    lines = if location, do: lines ++ ["LOCATION:#{escape_value(location)}"], else: lines

    # URL
    url = Map.get(event, :url) || Map.get(event, "url")
    lines = if url, do: lines ++ ["URL:#{url}"], else: lines

    # Status
    status = Map.get(event, :status, "CONFIRMED") || "CONFIRMED"
    lines = lines ++ ["STATUS:#{status}"]

    # Transparency
    transp = Map.get(event, :transparency, "OPAQUE") || "OPAQUE"
    lines = lines ++ ["TRANSP:#{transp}"]

    # Class (classification)
    classification = Map.get(event, :classification, "PUBLIC") || "PUBLIC"
    lines = lines ++ ["CLASS:#{classification}"]

    # Priority
    priority = Map.get(event, :priority, 0) || 0
    lines = if priority > 0, do: lines ++ ["PRIORITY:#{priority}"], else: lines

    # Recurrence
    rrule = Map.get(event, :rrule) || Map.get(event, "rrule")
    lines = if rrule, do: lines ++ ["RRULE:#{rrule}"], else: lines

    # Recurrence dates
    rdate = Map.get(event, :rdate, []) || []
    lines = if rdate != [], do: lines ++ format_rdates(rdate), else: lines

    # Exception dates
    exdate = Map.get(event, :exdate, []) || []
    lines = if exdate != [], do: lines ++ format_exdates(exdate), else: lines

    # Recurrence ID (for exceptions)
    recurrence_id = Map.get(event, :recurrence_id) || Map.get(event, "recurrence_id")

    lines =
      if recurrence_id,
        do: lines ++ ["RECURRENCE-ID:#{format_datetime(recurrence_id)}"],
        else: lines

    # Categories
    categories = Map.get(event, :categories, []) || []

    lines =
      if categories != [], do: lines ++ ["CATEGORIES:#{Enum.join(categories, ",")}"], else: lines

    # Organizer
    organizer = Map.get(event, :organizer) || Map.get(event, "organizer")
    lines = if organizer, do: lines ++ [format_organizer(organizer)], else: lines

    # Attendees
    attendees = Map.get(event, :attendees, []) || []
    lines = lines ++ Enum.flat_map(attendees, &format_attendee/1)

    # Alarms
    alarms = Map.get(event, :alarms, []) || []
    lines = lines ++ Enum.flat_map(alarms, &format_alarm/1)

    # Sequence (for updates)
    sequence = Map.get(event, :sequence, 0) || 0
    lines = lines ++ ["SEQUENCE:#{sequence}"]

    # Created/Last-modified
    created = Map.get(event, :inserted_at) || dtstamp
    modified = Map.get(event, :updated_at) || dtstamp

    lines =
      lines ++
        [
          "CREATED:#{format_datetime(created)}",
          "LAST-MODIFIED:#{format_datetime(modified)}"
        ]

    lines = lines ++ ["END:VEVENT", "END:VCALENDAR"]

    # Fold long lines
    folded = Enum.map(lines, &fold_line/1)

    {:ok, Enum.join(folded, "\r\n") <> "\r\n"}
  end

  @doc """
  Generate a unique UID for an event.
  """
  def generate_uid do
    uuid =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")

    "#{uuid}@elektrine.com"
  end

  @doc """
  Generate an etag from event data.
  """
  def generate_etag(event) do
    data = "#{event.uid}#{event.sequence}#{event.updated_at}"
    :crypto.hash(:md5, data) |> Base.encode16(case: :lower)
  end

  # Private functions - Parsing

  defp unfold_lines(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
  end

  defp extract_vevent(lines) do
    # Find VEVENT boundaries
    result =
      Enum.reduce_while(lines, {false, []}, fn line, {in_event, acc} ->
        cond do
          String.starts_with?(line, "BEGIN:VEVENT") ->
            {:cont, {true, []}}

          String.starts_with?(line, "END:VEVENT") ->
            {:halt, {false, acc}}

          in_event ->
            {:cont, {true, acc ++ [line]}}

          true ->
            {:cont, {in_event, acc}}
        end
      end)

    case result do
      {_, event_lines} when event_lines != [] ->
        {:ok, event_lines}

      _ ->
        {:error, :no_vevent_found}
    end
  end

  defp parse_event_lines(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case parse_line(line) do
        {property, params, value} ->
          parse_property(acc, property, params, value)

        _ ->
          acc
      end
    end)
  end

  defp parse_line(line) do
    case String.split(line, ":", parts: 2) do
      [property_part, value] ->
        {property, params} = parse_property_and_params(property_part)
        {property, params, value}

      _ ->
        nil
    end
  end

  defp parse_property_and_params(property_part) do
    parts = String.split(property_part, ";")
    property = List.first(parts) |> String.upcase()

    params =
      parts
      |> Enum.drop(1)
      |> Enum.map(&parse_param/1)
      |> Map.new()

    {property, params}
  end

  defp parse_param(param_str) do
    case String.split(param_str, "=", parts: 2) do
      [key, value] -> {String.upcase(key), value}
      [key] -> {String.upcase(key), true}
    end
  end

  defp parse_property(acc, "UID", _params, value) do
    Map.put(acc, :uid, value)
  end

  defp parse_property(acc, "SUMMARY", _params, value) do
    Map.put(acc, :summary, unescape_value(value))
  end

  defp parse_property(acc, "DESCRIPTION", _params, value) do
    Map.put(acc, :description, unescape_value(value))
  end

  defp parse_property(acc, "LOCATION", _params, value) do
    Map.put(acc, :location, unescape_value(value))
  end

  defp parse_property(acc, "URL", _params, value) do
    Map.put(acc, :url, value)
  end

  defp parse_property(acc, "DTSTART", params, value) do
    {dt, all_day, tz} = parse_datetime_value(value, params)

    acc
    |> Map.put(:dtstart, dt)
    |> Map.put(:all_day, all_day)
    |> Map.put(:timezone, tz || Map.get(acc, :timezone))
  end

  defp parse_property(acc, "DTEND", params, value) do
    {dt, _all_day, _tz} = parse_datetime_value(value, params)
    Map.put(acc, :dtend, dt)
  end

  defp parse_property(acc, "DURATION", _params, value) do
    Map.put(acc, :duration, value)
  end

  defp parse_property(acc, "RRULE", _params, value) do
    Map.put(acc, :rrule, value)
  end

  defp parse_property(acc, "RDATE", _params, value) do
    dates = String.split(value, ",") |> Enum.map(&parse_datetime_simple/1)
    current = Map.get(acc, :rdate, [])
    Map.put(acc, :rdate, current ++ dates)
  end

  defp parse_property(acc, "EXDATE", _params, value) do
    dates = String.split(value, ",") |> Enum.map(&parse_datetime_simple/1)
    current = Map.get(acc, :exdate, [])
    Map.put(acc, :exdate, current ++ dates)
  end

  defp parse_property(acc, "RECURRENCE-ID", _params, value) do
    Map.put(acc, :recurrence_id, parse_datetime_simple(value))
  end

  defp parse_property(acc, "STATUS", _params, value) do
    Map.put(acc, :status, String.upcase(value))
  end

  defp parse_property(acc, "TRANSP", _params, value) do
    Map.put(acc, :transparency, String.upcase(value))
  end

  defp parse_property(acc, "CLASS", _params, value) do
    Map.put(acc, :classification, String.upcase(value))
  end

  defp parse_property(acc, "PRIORITY", _params, value) do
    case Integer.parse(value) do
      {n, _} -> Map.put(acc, :priority, n)
      :error -> acc
    end
  end

  defp parse_property(acc, "SEQUENCE", _params, value) do
    case Integer.parse(value) do
      {n, _} -> Map.put(acc, :sequence, n)
      :error -> acc
    end
  end

  defp parse_property(acc, "CATEGORIES", _params, value) do
    categories = String.split(value, ",") |> Enum.map(&String.trim/1)
    Map.put(acc, :categories, categories)
  end

  defp parse_property(acc, "ORGANIZER", params, value) do
    organizer = %{
      "email" => extract_mailto(value),
      "cn" => Map.get(params, "CN")
    }

    Map.put(acc, :organizer, organizer)
  end

  defp parse_property(acc, "ATTENDEE", params, value) do
    attendee = %{
      "email" => extract_mailto(value),
      "cn" => Map.get(params, "CN"),
      "partstat" => Map.get(params, "PARTSTAT", "NEEDS-ACTION"),
      "role" => Map.get(params, "ROLE", "REQ-PARTICIPANT"),
      "rsvp" => Map.get(params, "RSVP") == "TRUE"
    }

    current = Map.get(acc, :attendees, [])
    Map.put(acc, :attendees, current ++ [attendee])
  end

  defp parse_property(acc, _property, _params, _value) do
    acc
  end

  defp extract_mailto(value) do
    case Regex.run(~r/mailto:(.+)/i, value) do
      [_, email] -> email
      _ -> value
    end
  end

  defp parse_datetime_value(value, params) do
    tzid = Map.get(params, "TZID")
    is_date = Map.get(params, "VALUE") == "DATE"

    cond do
      is_date || String.length(value) == 8 ->
        # All-day date: YYYYMMDD
        {parse_date_only(value), true, tzid}

      String.ends_with?(value, "Z") ->
        # UTC datetime
        {parse_datetime_simple(value), false, "UTC"}

      true ->
        # Local or TZID datetime
        {parse_datetime_simple(value), false, tzid}
    end
  end

  defp parse_date_only(value) do
    year = String.slice(value, 0..3)
    month = String.slice(value, 4..5)
    day = String.slice(value, 6..7)

    case Date.from_iso8601("#{year}-#{month}-#{day}") do
      {:ok, date} ->
        DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

      _ ->
        nil
    end
  end

  defp parse_datetime_simple(value) do
    # Parse YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ
    value = String.replace(value, "Z", "")

    if String.length(value) >= 15 do
      year = String.slice(value, 0..3)
      month = String.slice(value, 4..5)
      day = String.slice(value, 6..7)
      hour = String.slice(value, 9..10)
      min = String.slice(value, 11..12)
      sec = String.slice(value, 13..14)

      case NaiveDateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{min}:#{sec}") do
        {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
        _ -> nil
      end
    else
      parse_date_only(value)
    end
  end

  # Private functions - Generation

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y%m%dT%H%M%SZ")
  end

  defp format_datetime(nil), do: format_datetime(DateTime.utc_now())

  defp format_dtstart(dt, true, _tz) do
    # All-day event
    date_str = Calendar.strftime(dt, "%Y%m%d")
    "DTSTART;VALUE=DATE:#{date_str}"
  end

  defp format_dtstart(dt, false, nil) do
    "DTSTART:#{format_datetime(dt)}"
  end

  defp format_dtstart(dt, false, tz) when tz in ["UTC", "Etc/UTC"] do
    "DTSTART:#{format_datetime(dt)}"
  end

  defp format_dtstart(dt, false, tz) do
    dt_str = Calendar.strftime(dt, "%Y%m%dT%H%M%S")
    "DTSTART;TZID=#{tz}:#{dt_str}"
  end

  defp format_dtend(dt, true, _tz) do
    date_str = Calendar.strftime(dt, "%Y%m%d")
    "DTEND;VALUE=DATE:#{date_str}"
  end

  defp format_dtend(dt, false, nil) do
    "DTEND:#{format_datetime(dt)}"
  end

  defp format_dtend(dt, false, tz) when tz in ["UTC", "Etc/UTC"] do
    "DTEND:#{format_datetime(dt)}"
  end

  defp format_dtend(dt, false, tz) do
    dt_str = Calendar.strftime(dt, "%Y%m%dT%H%M%S")
    "DTEND;TZID=#{tz}:#{dt_str}"
  end

  defp format_rdates(dates) do
    dates
    |> Enum.filter(&(&1 != nil))
    |> Enum.map(&format_datetime/1)
    |> Enum.map(&"RDATE:#{&1}")
  end

  defp format_exdates(dates) do
    dates
    |> Enum.filter(&(&1 != nil))
    |> Enum.map(&format_datetime/1)
    |> Enum.map(&"EXDATE:#{&1}")
  end

  defp format_organizer(organizer) do
    email = Map.get(organizer, "email") || Map.get(organizer, :email)
    cn = Map.get(organizer, "cn") || Map.get(organizer, :cn)

    if cn do
      "ORGANIZER;CN=#{cn}:mailto:#{email}"
    else
      "ORGANIZER:mailto:#{email}"
    end
  end

  defp format_attendee(attendee) do
    email = Map.get(attendee, "email") || Map.get(attendee, :email)
    cn = Map.get(attendee, "cn") || Map.get(attendee, :cn)
    partstat = Map.get(attendee, "partstat") || Map.get(attendee, :partstat) || "NEEDS-ACTION"
    role = Map.get(attendee, "role") || Map.get(attendee, :role) || "REQ-PARTICIPANT"
    rsvp = Map.get(attendee, "rsvp", false) || Map.get(attendee, :rsvp, false)

    params = ["PARTSTAT=#{partstat}", "ROLE=#{role}"]
    params = if cn, do: ["CN=#{cn}" | params], else: params
    params = if rsvp, do: params ++ ["RSVP=TRUE"], else: params

    ["ATTENDEE;#{Enum.join(params, ";")}:mailto:#{email}"]
  end

  defp format_alarm(alarm) do
    action = Map.get(alarm, "action") || Map.get(alarm, :action) || "DISPLAY"
    trigger = Map.get(alarm, "trigger") || Map.get(alarm, :trigger) || "-PT15M"
    description = Map.get(alarm, "description") || Map.get(alarm, :description) || "Reminder"

    [
      "BEGIN:VALARM",
      "ACTION:#{action}",
      "TRIGGER:#{trigger}",
      "DESCRIPTION:#{escape_value(description)}",
      "END:VALARM"
    ]
  end

  defp build_vtimezone(_tz) do
    # Simplified - in production would generate proper VTIMEZONE
    []
  end

  defp unescape_value(value) when is_binary(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  defp unescape_value(nil), do: nil

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp escape_value(nil), do: ""

  defp fold_line(line) when byte_size(line) <= 75, do: line

  defp fold_line(line) do
    do_fold(line, [])
    |> Enum.reverse()
    |> Enum.join("\r\n ")
  end

  defp do_fold(<<>>, acc), do: acc

  defp do_fold(line, []) do
    {chunk, rest} = safe_split(line, 75)
    do_fold(rest, [chunk])
  end

  defp do_fold(line, acc) do
    {chunk, rest} = safe_split(line, 74)
    do_fold(rest, [chunk | acc])
  end

  defp safe_split(binary, max_bytes) do
    if byte_size(binary) <= max_bytes do
      {binary, <<>>}
    else
      safe_point = find_safe_split(binary, max_bytes)
      {String.slice(binary, 0, safe_point), String.slice(binary, safe_point..-1//1)}
    end
  end

  defp find_safe_split(binary, max) do
    Enum.reduce_while(max..1//-1, max, fn pos, _acc ->
      chunk = :binary.part(binary, 0, pos)

      if String.valid?(chunk) do
        {:halt, pos}
      else
        {:cont, pos - 1}
      end
    end)
  end
end
