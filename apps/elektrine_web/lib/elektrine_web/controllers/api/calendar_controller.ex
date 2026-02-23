defmodule ElektrineWeb.API.CalendarController do
  @moduledoc """
  External API controller for calendars and events.
  """
  use ElektrineWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Calendar, as: CalendarContext
  alias Elektrine.Calendar.Calendar, as: CalendarSchema
  alias Elektrine.Calendar.Event, as: EventSchema
  alias Elektrine.Repo

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/ext/calendars
  """
  def index(conn, _params) do
    user = conn.assigns.current_user
    calendars = CalendarContext.list_calendars(user.id)

    conn
    |> put_status(:ok)
    |> json(%{calendars: Enum.map(calendars, &format_calendar/1)})
  end

  @doc """
  POST /api/ext/calendars
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = params |> calendar_payload() |> Map.put("user_id", user.id)

    case CalendarContext.create_calendar(attrs) do
      {:ok, calendar} ->
        conn
        |> put_status(:created)
        |> json(%{calendar: format_calendar(calendar)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/ext/calendars/:id/events
  """
  def events(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, calendar} <- get_user_calendar(user.id, id),
         {:ok, range_mode, start_dt, end_dt} <- parse_range(params) do
      events =
        case range_mode do
          :all -> CalendarContext.list_events(calendar.id)
          :range -> CalendarContext.list_events_in_range(calendar.id, start_dt, end_dt)
        end

      conn
      |> put_status(:ok)
      |> json(%{
        calendar: format_calendar(calendar),
        events: Enum.map(events, &format_event/1)
      })
    else
      {:error, :invalid_range} ->
        bad_request(conn, "Invalid date range. Use ISO8601 start/end values.")

      {:error, :partial_range} ->
        bad_request(conn, "Both start and end are required when filtering by range.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  POST /api/ext/calendars/:id/events
  """
  def create_event(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, calendar} <- get_user_calendar(user.id, id) do
      attrs = params |> event_payload() |> Map.put("calendar_id", calendar.id)

      case CalendarContext.create_event(attrs) do
        {:ok, event} ->
          conn
          |> put_status(:created)
          |> json(%{event: format_event(event)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  PUT /api/ext/events/:id
  """
  def update_event(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, event} <- get_user_event(user.id, id) do
      case CalendarContext.update_event(event, event_payload(params)) do
        {:ok, updated_event} ->
          conn
          |> put_status(:ok)
          |> json(%{event: format_event(updated_event)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  DELETE /api/ext/events/:id
  """
  def delete_event(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, event} <- get_user_event(user.id, id),
         {:ok, _deleted_event} <- CalendarContext.delete_event(event) do
      conn
      |> put_status(:ok)
      |> json(%{message: "Event deleted"})
    end
  end

  defp calendar_payload(params) do
    source = Map.get(params, "calendar", params)
    Map.take(source, ~w(name color description timezone is_default order))
  end

  defp event_payload(params) do
    source = Map.get(params, "event", params)

    Map.take(source, [
      "uid",
      "summary",
      "description",
      "location",
      "url",
      "dtstart",
      "dtend",
      "duration",
      "all_day",
      "timezone",
      "rrule",
      "rdate",
      "exdate",
      "recurrence_id",
      "status",
      "transparency",
      "classification",
      "priority",
      "alarms",
      "attendees",
      "organizer",
      "categories",
      "icalendar_data"
    ])
  end

  defp get_user_calendar(user_id, id) do
    with {:ok, calendar_id} <- parse_id(id),
         %CalendarSchema{} = calendar <-
           Repo.get_by(CalendarSchema, id: calendar_id, user_id: user_id) do
      {:ok, calendar}
    else
      :error -> {:error, :bad_request}
      nil -> {:error, :not_found}
    end
  end

  defp get_user_event(user_id, id) do
    with {:ok, event_id} <- parse_id(id) do
      query =
        from(e in EventSchema,
          join: c in CalendarSchema,
          on: c.id == e.calendar_id,
          where: e.id == ^event_id and c.user_id == ^user_id
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        event -> {:ok, event}
      end
    else
      :error -> {:error, :bad_request}
    end
  end

  defp parse_range(%{"start" => start_raw, "end" => end_raw}) do
    with {:ok, start_dt} <- parse_datetime(start_raw),
         {:ok, end_dt} <- parse_datetime(end_raw),
         true <- DateTime.compare(end_dt, start_dt) in [:gt, :eq] do
      {:ok, :range, start_dt, end_dt}
    else
      false -> {:error, :invalid_range}
      _ -> {:error, :invalid_range}
    end
  end

  defp parse_range(%{"start" => _}), do: {:error, :partial_range}
  defp parse_range(%{"end" => _}), do: {:error, :partial_range}
  defp parse_range(_), do: {:ok, :all, nil, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_datetime} -> {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}
          _ -> {:error, :invalid_datetime}
        end
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end

  defp format_calendar(calendar) do
    %{
      id: calendar.id,
      name: calendar.name,
      color: calendar.color,
      description: calendar.description,
      timezone: calendar.timezone,
      is_default: calendar.is_default,
      order: calendar.order,
      ctag: calendar.ctag,
      inserted_at: calendar.inserted_at,
      updated_at: calendar.updated_at
    }
  end

  defp format_event(event) do
    %{
      id: event.id,
      calendar_id: event.calendar_id,
      uid: event.uid,
      etag: event.etag,
      summary: event.summary,
      description: event.description,
      location: event.location,
      url: event.url,
      dtstart: event.dtstart,
      dtend: event.dtend,
      duration: event.duration,
      all_day: event.all_day,
      timezone: event.timezone,
      rrule: event.rrule,
      rdate: event.rdate,
      exdate: event.exdate,
      recurrence_id: event.recurrence_id,
      status: event.status,
      transparency: event.transparency,
      classification: event.classification,
      priority: event.priority,
      alarms: event.alarms,
      attendees: event.attendees,
      organizer: event.organizer,
      categories: event.categories,
      sequence: event.sequence,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end
end
