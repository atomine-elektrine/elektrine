defmodule ElektrineWeb.CalendarLive.Operations.CalendarOperations do
  @moduledoc """
  Handles calendar-related events for the CalendarLive module.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Elektrine.Calendar, as: Cal
  alias Elektrine.Calendar.Calendar, as: CalendarSchema
  alias Elektrine.Calendar.Event
  alias ElektrineWeb.CalendarLive.Index

  # Navigation
  def handle_calendar_event("prev_month", _params, socket) do
    new_date = Date.add(socket.assigns.view_date, -30)
    reload_events(socket, new_date)
  end

  def handle_calendar_event("next_month", _params, socket) do
    new_date = Date.add(socket.assigns.view_date, 30)
    reload_events(socket, new_date)
  end

  def handle_calendar_event("today", _params, socket) do
    reload_events(socket, Date.utc_today())
  end

  # Calendar visibility toggle
  def handle_calendar_event("toggle_calendar", %{"id" => id}, socket) do
    id = to_int(id)
    visible = socket.assigns.visible_calendars

    new_visible =
      if MapSet.member?(visible, id) do
        MapSet.delete(visible, id)
      else
        MapSet.put(visible, id)
      end

    {:noreply, assign(socket, :visible_calendars, new_visible)}
  end

  # Select a date
  def handle_calendar_event("select_date", %{"date" => date_str}, socket) do
    {:ok, date} = Date.from_iso8601(date_str)
    {:noreply, assign(socket, :selected_date, date)}
  end

  def handle_calendar_event("close_date_detail", _params, socket) do
    {:noreply, assign(socket, :selected_date, nil)}
  end

  # Event CRUD
  def handle_calendar_event("new_event", params, socket) do
    date =
      case params do
        %{"date" => date_str} ->
          {:ok, d} = Date.from_iso8601(date_str)
          d

        _ ->
          socket.assigns.selected_date || socket.assigns.current_date
      end

    # Default to 9am start, 10am end
    dtstart = DateTime.new!(date, ~T[09:00:00], "Etc/UTC")
    dtend = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

    changeset =
      Event.changeset(%Event{}, %{
        dtstart: dtstart,
        dtend: dtend,
        calendar_id: socket.assigns.default_calendar.id
      })

    {:noreply,
     socket
     |> assign(:show_event_modal, true)
     |> assign(:editing_event, nil)
     |> assign(:event_changeset, changeset)}
  end

  def handle_calendar_event("edit_event", %{"id" => id}, socket) do
    event = Cal.get_event!(to_int(id))
    changeset = Event.changeset(event, %{})

    {:noreply,
     socket
     |> assign(:show_event_modal, true)
     |> assign(:editing_event, event)
     |> assign(:event_changeset, changeset)}
  end

  def handle_calendar_event("view_event", %{"id" => id}, socket) do
    event = Cal.get_event!(to_int(id)) |> Elektrine.Repo.preload(:calendar)
    {:noreply, assign(socket, :selected_event, event)}
  end

  def handle_calendar_event("close_event_detail", _params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  def handle_calendar_event("cancel_event_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_event_modal, false)
     |> assign(:editing_event, nil)}
  end

  def handle_calendar_event("validate_event", %{"event" => params}, socket) do
    event = socket.assigns.editing_event || %Event{}
    changeset = Event.changeset(event, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :event_changeset, changeset)}
  end

  def handle_calendar_event("save_event", %{"event" => params}, socket) do
    # Parse date and time into DateTime
    params = parse_event_datetime(params)

    result =
      if socket.assigns.editing_event do
        Cal.update_event(socket.assigns.editing_event, params)
      else
        # Generate UID if not present
        params = Map.put_new(params, "uid", Ecto.UUID.generate())
        Cal.create_event(params)
      end

    case result do
      {:ok, event} ->
        event = Elektrine.Repo.preload(event, :calendar)

        events =
          if socket.assigns.editing_event do
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: event, else: e
            end)
          else
            [event | socket.assigns.events]
          end

        {:noreply,
         socket
         |> assign(:events, events)
         |> assign(:show_event_modal, false)
         |> assign(:editing_event, nil)
         |> assign(:selected_event, nil)
         |> put_flash(:info, gettext("Event saved successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :event_changeset, changeset)}
    end
  end

  def handle_calendar_event("delete_event", %{"id" => id}, socket) do
    id = to_int(id)
    event = Cal.get_event!(id)

    case Cal.delete_event(event) do
      {:ok, _} ->
        events = Enum.reject(socket.assigns.events, &(&1.id == id))

        {:noreply,
         socket
         |> assign(:events, events)
         |> assign(:selected_event, nil)
         |> put_flash(:info, gettext("Event deleted"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete event"))}
    end
  end

  # Calendar management
  def handle_calendar_event("new_calendar", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_calendar_modal, true)
     |> assign(:editing_calendar, nil)
     |> assign(:calendar_changeset, CalendarSchema.changeset(%CalendarSchema{}, %{}))}
  end

  def handle_calendar_event("edit_calendar", %{"id" => id}, socket) do
    calendar = Cal.get_calendar!(to_int(id))
    changeset = CalendarSchema.changeset(calendar, %{})

    {:noreply,
     socket
     |> assign(:show_calendar_modal, true)
     |> assign(:editing_calendar, calendar)
     |> assign(:calendar_changeset, changeset)}
  end

  def handle_calendar_event("cancel_calendar_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_calendar_modal, false)
     |> assign(:editing_calendar, nil)}
  end

  def handle_calendar_event("validate_calendar", %{"calendar" => params}, socket) do
    calendar = socket.assigns.editing_calendar || %CalendarSchema{}
    changeset = CalendarSchema.changeset(calendar, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :calendar_changeset, changeset)}
  end

  def handle_calendar_event("save_calendar", %{"calendar" => params}, socket) do
    user = socket.assigns.current_user

    result =
      if socket.assigns.editing_calendar do
        Cal.update_calendar(socket.assigns.editing_calendar, params)
      else
        params = Map.put(params, "user_id", user.id)
        Cal.create_calendar(params)
      end

    case result do
      {:ok, calendar} ->
        calendars =
          if socket.assigns.editing_calendar do
            Enum.map(socket.assigns.calendars, fn c ->
              if c.id == calendar.id, do: calendar, else: c
            end)
          else
            socket.assigns.calendars ++ [calendar]
          end

        visible = MapSet.put(socket.assigns.visible_calendars, calendar.id)

        {:noreply,
         socket
         |> assign(:calendars, calendars)
         |> assign(:visible_calendars, visible)
         |> assign(:show_calendar_modal, false)
         |> assign(:editing_calendar, nil)
         |> put_flash(:info, gettext("Calendar saved successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :calendar_changeset, changeset)}
    end
  end

  def handle_calendar_event("delete_calendar", %{"id" => id}, socket) do
    id = to_int(id)
    calendar = Cal.get_calendar!(id)

    if calendar.is_default do
      {:noreply, put_flash(socket, :error, gettext("Cannot delete default calendar"))}
    else
      case Cal.delete_calendar(calendar) do
        {:ok, _} ->
          calendars = Enum.reject(socket.assigns.calendars, &(&1.id == id))
          visible = MapSet.delete(socket.assigns.visible_calendars, id)
          events = Enum.reject(socket.assigns.events, &(&1.calendar_id == id))

          {:noreply,
           socket
           |> assign(:calendars, calendars)
           |> assign(:visible_calendars, visible)
           |> assign(:events, events)
           |> assign(:show_calendar_modal, false)
           |> put_flash(:info, gettext("Calendar deleted"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete calendar"))}
      end
    end
  end

  # Catch-all
  def handle_calendar_event(event, params, socket) do
    require Logger
    Logger.warning("Unhandled calendar event: #{event} with params: #{inspect(params)}")
    {:noreply, socket}
  end

  # Helper functions
  defp reload_events(socket, new_date) do
    user = socket.assigns.current_user
    {start_date, end_date} = Index.get_month_range(new_date)
    events = Cal.list_user_events_in_range(user.id, start_date, end_date)

    {:noreply,
     socket
     |> assign(:view_date, new_date)
     |> assign(:events, events)}
  end

  defp parse_event_datetime(params) do
    date = params["date"] || Date.to_iso8601(Date.utc_today())
    start_time = params["start_time"] || "09:00"
    end_time = params["end_time"] || "10:00"

    {:ok, date} = Date.from_iso8601(date)
    {:ok, start_t} = Time.from_iso8601(start_time <> ":00")
    {:ok, end_t} = Time.from_iso8601(end_time <> ":00")

    dtstart = DateTime.new!(date, start_t, "Etc/UTC")
    dtend = DateTime.new!(date, end_t, "Etc/UTC")

    params
    |> Map.put("dtstart", dtstart)
    |> Map.put("dtend", dtend)
  end

  defp gettext(msg), do: Gettext.gettext(ElektrineWeb.Gettext, msg)

  defp to_int(id) when is_binary(id), do: String.to_integer(id)
  defp to_int(id) when is_integer(id), do: id
end
