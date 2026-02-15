defmodule Elektrine.Calendar do
  @moduledoc """
  Context for calendar and event management.
  Provides functions for both web UI and CalDAV operations.
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Calendar.{Calendar, Event, ICalendar}

  # ===== CALENDARS =====

  @doc """
  Lists all calendars for a user.
  """
  def list_calendars(user_id) do
    from(c in Calendar,
      where: c.user_id == ^user_id,
      order_by: [asc: c.order, asc: c.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single calendar.
  """
  def get_calendar!(id) do
    Repo.get!(Calendar, id)
  end

  @doc """
  Gets a calendar by user_id and name.
  """
  def get_calendar_by_name(user_id, name) do
    Repo.get_by(Calendar, user_id: user_id, name: name)
  end

  @doc """
  Gets the default calendar for a user, creating one if needed.
  """
  def get_or_create_default_calendar(user_id) do
    case Repo.get_by(Calendar, user_id: user_id, is_default: true) do
      nil ->
        create_calendar(%{
          user_id: user_id,
          name: "Default",
          is_default: true,
          color: "#3b82f6"
        })

      calendar ->
        {:ok, calendar}
    end
  end

  @doc """
  Creates a calendar.
  """
  def create_calendar(attrs) do
    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a calendar.
  """
  def update_calendar(%Calendar{} = calendar, attrs) do
    calendar
    |> Calendar.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a calendar and all its events.
  """
  def delete_calendar(%Calendar{} = calendar) do
    Repo.delete(calendar)
  end

  @doc """
  Updates the ctag for a calendar (for sync detection).
  """
  def update_calendar_ctag(%Calendar{} = calendar) do
    ctag = "ctag-#{DateTime.utc_now() |> DateTime.to_unix()}"

    calendar
    |> Ecto.Changeset.change(%{ctag: ctag})
    |> Repo.update()
  end

  # ===== EVENTS =====

  @doc """
  Lists all events in a calendar.
  """
  def list_events(calendar_id) do
    from(e in Event,
      where: e.calendar_id == ^calendar_id,
      order_by: [asc: e.dtstart]
    )
    |> Repo.all()
  end

  @doc """
  Lists events in a date range.
  """
  def list_events_in_range(calendar_id, start_date, end_date) do
    from(e in Event,
      where: e.calendar_id == ^calendar_id,
      where: e.dtstart >= ^start_date and e.dtstart <= ^end_date,
      order_by: [asc: e.dtstart]
    )
    |> Repo.all()
  end

  @doc """
  Lists events across all user's calendars in a date range.
  """
  def list_user_events_in_range(user_id, start_date, end_date) do
    from(e in Event,
      join: c in Calendar,
      on: e.calendar_id == c.id,
      where: c.user_id == ^user_id,
      where: e.dtstart >= ^start_date and e.dtstart <= ^end_date,
      order_by: [asc: e.dtstart],
      preload: [:calendar]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single event.
  """
  def get_event!(id) do
    Repo.get!(Event, id)
  end

  @doc """
  Gets an event by its UID within a calendar.
  """
  def get_event_by_uid(calendar_id, uid) do
    Repo.get_by(Event, calendar_id: calendar_id, uid: uid)
  end

  @doc """
  Creates an event.
  """
  def create_event(attrs) do
    result =
      %Event{}
      |> Event.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, event} ->
        # Update calendar ctag
        calendar = get_calendar!(event.calendar_id)
        update_calendar_ctag(calendar)
        {:ok, event}

      error ->
        error
    end
  end

  @doc """
  Updates an event.
  """
  def update_event(%Event{} = event, attrs) do
    result =
      event
      |> Event.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_event} ->
        # Update calendar ctag
        calendar = get_calendar!(updated_event.calendar_id)
        update_calendar_ctag(calendar)
        {:ok, updated_event}

      error ->
        error
    end
  end

  @doc """
  Deletes an event.
  """
  def delete_event(%Event{} = event) do
    calendar_id = event.calendar_id

    result = Repo.delete(event)

    case result do
      {:ok, _} ->
        # Update calendar ctag
        calendar = get_calendar!(calendar_id)
        update_calendar_ctag(calendar)
        result

      error ->
        error
    end
  end

  # ===== CALDAV OPERATIONS =====

  @doc """
  Creates or updates an event from CalDAV PUT request.
  """
  def upsert_event_from_icalendar(calendar_id, uid, icalendar_data) do
    case ICalendar.parse(icalendar_data) do
      {:ok, event_data} ->
        attrs =
          Map.merge(event_data, %{
            calendar_id: calendar_id,
            uid: uid,
            icalendar_data: icalendar_data
          })

        case get_event_by_uid(calendar_id, uid) do
          nil ->
            # Create new event
            %Event{}
            |> Event.caldav_changeset(attrs)
            |> Repo.insert()

          existing ->
            # Update existing event
            existing
            |> Event.caldav_changeset(attrs)
            |> Repo.update()
        end
        |> tap_update_ctag(calendar_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists events modified since a given timestamp (for sync).
  """
  def list_events_since(calendar_id, nil) do
    list_events(calendar_id)
  end

  def list_events_since(calendar_id, %DateTime{} = since) do
    from(e in Event,
      where: e.calendar_id == ^calendar_id and e.updated_at > ^since,
      order_by: [asc: e.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Generates iCalendar data for an event if not already present.
  """
  def ensure_icalendar_data(%Event{icalendar_data: nil} = event) do
    {:ok, ical_data} = ICalendar.generate(event)
    ical_data
  end

  def ensure_icalendar_data(%Event{icalendar_data: data}), do: data

  # Private helpers

  defp tap_update_ctag({:ok, event}, calendar_id) do
    calendar = get_calendar!(calendar_id)
    update_calendar_ctag(calendar)
    {:ok, event}
  end

  defp tap_update_ctag(error, _calendar_id), do: error
end
