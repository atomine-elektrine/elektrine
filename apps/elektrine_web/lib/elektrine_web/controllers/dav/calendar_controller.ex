defmodule ElektrineWeb.DAV.CalendarController do
  @moduledoc """
  CalDAV controller for calendar synchronization.

  Implements RFC 4791 (CalDAV) for calendar sync with:
  - iOS/macOS Calendar
  - Thunderbird
  - DAVx5 (Android)
  - Other CalDAV clients
  """

  use ElektrineWeb, :controller

  alias ElektrineWeb.DAV.{ResponseHelpers, Properties}
  alias Elektrine.Calendar

  require Logger

  @doc """
  PROPFIND on calendar home - lists available calendars.
  """
  def propfind_home(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      base_url = base_url(conn)
      depth = ResponseHelpers.get_depth(conn)

      responses = [
        %{
          href: "#{base_url}/calendars/#{username}/",
          propstat: [{200, Properties.calendar_home_props(user, base_url)}]
        }
      ]

      # If depth > 0, include all calendars
      responses =
        if depth != 0 do
          calendars = Calendar.list_calendars(user.id)

          calendar_responses =
            Enum.map(calendars, fn calendar ->
              %{
                href: "#{base_url}/calendars/#{username}/#{calendar.id}/",
                propstat: [{200, Properties.calendar_props(calendar, base_url, user)}]
              }
            end)

          responses ++ calendar_responses
        else
          responses
        end

      ResponseHelpers.send_multistatus(conn, responses)
    end
  end

  @doc """
  PROPFIND on a specific calendar - lists events or properties.
  """
  def propfind_calendar(conn, %{"username" => username, "calendar_id" => calendar_id}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      base_url = base_url(conn)
      depth = ResponseHelpers.get_depth(conn)

      case get_calendar(calendar_id, user.id) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        calendar ->
          responses = [
            %{
              href: "#{base_url}/calendars/#{username}/#{calendar_id}/",
              propstat: [{200, Properties.calendar_props(calendar, base_url, user)}]
            }
          ]

          # If depth > 0, include all events
          responses =
            if depth != 0 do
              events = Calendar.list_events(calendar.id)

              event_responses =
                Enum.map(events, fn event ->
                  %{
                    href: "#{base_url}/calendars/#{username}/#{calendar_id}/#{event.uid}.ics",
                    propstat: [{200, Properties.event_props(event)}]
                  }
                end)

              responses ++ event_responses
            else
              responses
            end

          ResponseHelpers.send_multistatus(conn, responses)
      end
    end
  end

  @doc """
  REPORT request - multiget, query, or sync events.
  """
  def report(conn, %{"username" => username, "calendar_id" => calendar_id}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      case get_calendar(calendar_id, user.id) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        calendar ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          cond do
            String.contains?(body, "calendar-multiget") ->
              handle_multiget(conn, user, calendar, body)

            String.contains?(body, "calendar-query") ->
              handle_query(conn, user, calendar, body)

            String.contains?(body, "sync-collection") ->
              handle_sync(conn, user, calendar, body)

            true ->
              ResponseHelpers.send_multistatus(conn, [])
          end
      end
    end
  end

  @doc """
  MKCALENDAR - create a new calendar.
  """
  def mkcalendar(conn, %{"username" => username, "calendar_id" => calendar_name}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      # Check if calendar already exists
      case Calendar.get_calendar_by_name(user.id, calendar_name) do
        nil ->
          # Parse request body for calendar properties
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          props = parse_mkcalendar_body(body)

          attrs =
            Map.merge(
              %{
                user_id: user.id,
                name: props[:displayname] || calendar_name
              },
              props
            )

          case Calendar.create_calendar(attrs) do
            {:ok, _calendar} ->
              ResponseHelpers.send_created(conn)

            {:error, _changeset} ->
              conn |> send_resp(500, "Failed to create calendar")
          end

        _existing ->
          conn |> send_resp(405, "Calendar already exists")
      end
    end
  end

  @doc """
  GET a single event as iCalendar.
  """
  def get_event(conn, %{
        "username" => username,
        "calendar_id" => calendar_id,
        "event_uid" => event_uid
      }) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      case get_calendar(calendar_id, user.id) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        calendar ->
          uid = String.replace_suffix(event_uid, ".ics", "")

          case Calendar.get_event_by_uid(calendar.id, uid) do
            nil ->
              ResponseHelpers.send_not_found(conn)

            event ->
              ical_data = Calendar.ensure_icalendar_data(event)
              ResponseHelpers.send_resource(conn, ical_data, "text/calendar", event.etag)
          end
      end
    end
  end

  @doc """
  PUT (create or update) an event.
  """
  def put_event(conn, %{
        "username" => username,
        "calendar_id" => calendar_id,
        "event_uid" => event_uid
      }) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      case get_calendar(calendar_id, user.id) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        calendar ->
          uid = String.replace_suffix(event_uid, ".ics", "")
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          # Check If-Match header for conditional update
          if_match = get_req_header(conn, "if-match") |> List.first()
          if_none_match = get_req_header(conn, "if-none-match") |> List.first()

          existing = Calendar.get_event_by_uid(calendar.id, uid)

          cond do
            # If-None-Match: * means only create, don't update
            if_none_match == "*" && existing ->
              ResponseHelpers.send_precondition_failed(conn)

            # If-Match means only update if etag matches
            if_match && existing && "\"#{existing.etag}\"" != if_match ->
              ResponseHelpers.send_precondition_failed(conn)

            # If-Match with no existing resource
            if_match && !existing ->
              ResponseHelpers.send_precondition_failed(conn)

            true ->
              case Calendar.upsert_event_from_icalendar(calendar.id, uid, body) do
                {:ok, event} ->
                  if existing do
                    ResponseHelpers.send_no_content(conn, event.etag)
                  else
                    ResponseHelpers.send_created(conn, event.etag)
                  end

                {:error, reason} ->
                  Logger.error("CalDAV PUT failed: #{inspect(reason)}")
                  conn |> send_resp(400, "Invalid iCalendar data")
              end
          end
      end
    end
  end

  @doc """
  DELETE an event.
  """
  def delete_event(conn, %{
        "username" => username,
        "calendar_id" => calendar_id,
        "event_uid" => event_uid
      }) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      case get_calendar(calendar_id, user.id) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        calendar ->
          uid = String.replace_suffix(event_uid, ".ics", "")

          case Calendar.get_event_by_uid(calendar.id, uid) do
            nil ->
              ResponseHelpers.send_not_found(conn)

            event ->
              case Calendar.delete_event(event) do
                {:ok, _} ->
                  ResponseHelpers.send_no_content(conn)

                {:error, _} ->
                  conn |> send_resp(500, "Failed to delete event")
              end
          end
      end
    end
  end

  # Private functions

  defp get_calendar(calendar_id, user_id) do
    # Handle both numeric IDs and calendar names
    case Integer.parse(to_string(calendar_id)) do
      {id, ""} ->
        calendar = Calendar.get_calendar!(id)
        if calendar.user_id == user_id, do: calendar, else: nil

      _ ->
        Calendar.get_calendar_by_name(user_id, calendar_id)
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp handle_multiget(conn, _user, calendar, body) do
    # Extract hrefs from request body
    hrefs = extract_hrefs(body)

    responses =
      Enum.map(hrefs, fn href ->
        uid =
          href
          |> String.split("/")
          |> List.last()
          |> String.replace_suffix(".ics", "")

        case Calendar.get_event_by_uid(calendar.id, uid) do
          nil ->
            %{href: href, propstat: [{404, []}]}

          event ->
            ical_data = Calendar.ensure_icalendar_data(event)
            props = Properties.event_props(event) ++ [{:calendar_data, ical_data}]
            %{href: href, propstat: [{200, props}]}
        end
      end)

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp handle_query(conn, user, calendar, body) do
    base_url = base_url(conn)

    # Parse time-range filter if present
    {start_date, end_date} = extract_time_range(body)

    events =
      if start_date && end_date do
        Calendar.list_events_in_range(calendar.id, start_date, end_date)
      else
        Calendar.list_events(calendar.id)
      end

    responses =
      Enum.map(events, fn event ->
        ical_data = Calendar.ensure_icalendar_data(event)
        props = Properties.event_props(event) ++ [{:calendar_data, ical_data}]

        %{
          href: "#{base_url}/calendars/#{user.username}/#{calendar.id}/#{event.uid}.ics",
          propstat: [{200, props}]
        }
      end)

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp handle_sync(conn, user, calendar, body) do
    base_url = base_url(conn)

    # Extract sync-token from request
    old_token = extract_sync_token(body)
    since = parse_sync_token(old_token)

    events = Calendar.list_events_since(calendar.id, since)

    responses =
      Enum.map(events, fn event ->
        props = Properties.event_props(event)

        %{
          href: "#{base_url}/calendars/#{user.username}/#{calendar.id}/#{event.uid}.ics",
          propstat: [{200, props}]
        }
      end)

    # Include new sync token
    new_token = "data:,#{Properties.generate_ctag(calendar)}"

    responses =
      responses ++
        [
          %{
            href: "#{base_url}/calendars/#{user.username}/#{calendar.id}/",
            propstat: [{200, [{:sync_token, new_token}]}]
          }
        ]

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp extract_hrefs(body) do
    Regex.scan(~r/<D:href>([^<]+)<\/D:href>/i, body)
    |> Enum.map(fn [_, href] -> href end)
  end

  defp extract_sync_token(body) do
    case Regex.run(~r/<D:sync-token>([^<]+)<\/D:sync-token>/i, body) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp parse_sync_token(nil), do: nil

  defp parse_sync_token("data:," <> ctag) do
    case String.split(ctag, "-") do
      ["ctag", timestamp] ->
        case Integer.parse(timestamp) do
          {ts, _} -> DateTime.from_unix!(ts)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_sync_token(_), do: nil

  defp extract_time_range(body) do
    # Parse CalDAV time-range filter
    # Format: <C:time-range start="20240101T000000Z" end="20240201T000000Z"/>
    start_match = Regex.run(~r/start="([^"]+)"/, body)
    end_match = Regex.run(~r/end="([^"]+)"/, body)

    start_dt =
      case start_match do
        [_, dt_str] -> parse_icalendar_datetime(dt_str)
        _ -> nil
      end

    end_dt =
      case end_match do
        [_, dt_str] -> parse_icalendar_datetime(dt_str)
        _ -> nil
      end

    {start_dt, end_dt}
  end

  defp parse_icalendar_datetime(str) do
    str = String.replace(str, "Z", "")

    if String.length(str) >= 15 do
      year = String.slice(str, 0..3)
      month = String.slice(str, 4..5)
      day = String.slice(str, 6..7)
      hour = String.slice(str, 9..10)
      min = String.slice(str, 11..12)
      sec = String.slice(str, 13..14)

      case NaiveDateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{min}:#{sec}") do
        {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
        _ -> nil
      end
    else
      nil
    end
  end

  defp parse_mkcalendar_body(body) when byte_size(body) == 0 do
    %{}
  end

  defp parse_mkcalendar_body(body) do
    # Parse MKCALENDAR request for display name, description, color
    props = %{}

    props =
      case Regex.run(~r/<D:displayname>([^<]+)<\/D:displayname>/i, body) do
        [_, name] -> Map.put(props, :name, name)
        _ -> props
      end

    props =
      case Regex.run(~r/<C:calendar-description>([^<]+)<\/C:calendar-description>/i, body) do
        [_, desc] -> Map.put(props, :description, desc)
        _ -> props
      end

    props =
      case Regex.run(~r/<(?:A|x1):calendar-color>([^<]+)<\/(?:A|x1):calendar-color>/i, body) do
        [_, color] -> Map.put(props, :color, color)
        _ -> props
      end

    props
  end

  defp base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{scheme}://#{conn.host}#{port}"
  end
end
