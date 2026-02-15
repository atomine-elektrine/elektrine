defmodule ElektrineWeb.CalendarLive.Index do
  use ElektrineWeb, :live_view

  import ElektrineWeb.Components.Platform.ElektrineNav
  import ElektrineWeb.EmailLive.EmailHelpers, only: [sidebar: 1]
  alias Elektrine.Calendar, as: Cal
  alias Elektrine.Calendar.Calendar, as: CalendarSchema
  alias Elektrine.Calendar.Event
  alias Elektrine.Email

  import ElektrineWeb.CalendarLive.Operations.CalendarOperations

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    today = Date.utc_today()
    mailbox = Email.get_user_mailbox(user.id)

    {:ok, cached_storage} =
      Elektrine.AppCache.get_storage_info(user.id, fn ->
        Elektrine.Accounts.Storage.get_storage_info(user.id)
      end)

    unread_count = if mailbox, do: Email.unread_count(mailbox.id), else: 0

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:calendar")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      # Load calendar data asynchronously after connection
      send(self(), :load_calendar_data)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Calendar"))
     |> assign(:loading_calendar, true)
     # Initialize with empty/default data - will be loaded asynchronously
     |> assign(:calendars, [])
     |> assign(:default_calendar, nil)
     |> assign(:events, [])
     |> assign(:current_date, today)
     |> assign(:view_date, today)
     |> assign(:view_mode, :month)
     |> assign(:selected_date, nil)
     |> assign(:selected_event, nil)
     |> assign(:show_event_modal, false)
     |> assign(:show_calendar_modal, false)
     |> assign(:editing_event, nil)
     |> assign(:editing_calendar, nil)
     |> assign(:event_changeset, Event.changeset(%Event{}, %{}))
     |> assign(:calendar_changeset, CalendarSchema.changeset(%CalendarSchema{}, %{}))
     |> assign(:visible_calendars, MapSet.new())
     |> assign(:mailbox, mailbox)
     |> assign(:unread_count, unread_count)
     |> assign(:storage_info, cached_storage)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Calendar"))
  end

  @impl true
  def handle_event(event, params, socket) do
    handle_calendar_event(event, params, socket)
  end

  @impl true
  def handle_info(:load_calendar_data, socket) do
    user = socket.assigns.current_user
    today = socket.assigns.current_date

    # Load calendar data in parallel
    default_cal_task = Task.async(fn -> Cal.get_or_create_default_calendar(user.id) end)
    calendars_task = Task.async(fn -> Cal.list_calendars(user.id) end)
    {:ok, default_calendar} = Task.await(default_cal_task)
    calendars = Task.await(calendars_task)
    mailbox = socket.assigns.mailbox

    # Load events and unread count (depends on previous results)
    {start_date, end_date} = get_month_range(today)

    events_task =
      Task.async(fn -> Cal.list_user_events_in_range(user.id, start_date, end_date) end)

    unread_task = Task.async(fn -> if mailbox, do: Email.unread_count(mailbox.id), else: 0 end)

    events = Task.await(events_task)
    unread_count = Task.await(unread_task)

    {:noreply,
     socket
     |> assign(:loading_calendar, false)
     |> assign(:calendars, calendars)
     |> assign(:default_calendar, default_calendar)
     |> assign(:events, events)
     |> assign(:visible_calendars, MapSet.new(Enum.map(calendars, & &1.id)))
     |> assign(:unread_count, unread_count)}
  end

  @impl true
  def handle_info({:event_updated, event}, socket) do
    events = update_event_in_list(socket.assigns.events, event)
    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:event_created, event}, socket) do
    # Check if event is in current view range
    {start_date, end_date} = get_month_range(socket.assigns.view_date)

    if Date.compare(event.dtstart, start_date) != :lt and
         Date.compare(event.dtstart, end_date) != :gt do
      events = [event | socket.assigns.events]
      {:noreply, assign(socket, :events, events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_deleted, event_id}, socket) do
    events = Enum.reject(socket.assigns.events, &(&1.id == event_id))
    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:unread_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :unread_count, new_count)}
  end

  # Catch-all for other messages (presence updates, etc.)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp update_event_in_list(events, updated_event) do
    Enum.map(events, fn e ->
      if e.id == updated_event.id, do: updated_event, else: e
    end)
  end

  # Date helpers
  def get_month_range(date) do
    first_of_month = Date.beginning_of_month(date)
    last_of_month = Date.end_of_month(date)

    # Get the start of the week containing the first of the month
    days_since_sunday = Date.day_of_week(first_of_month, :sunday) - 1
    start_date = Date.add(first_of_month, -days_since_sunday)

    # Get the end of the week containing the last of the month
    days_until_saturday = 7 - Date.day_of_week(last_of_month, :sunday)
    end_date = Date.add(last_of_month, days_until_saturday)

    # Convert to DateTime for database query (start of first day, end of last day)
    start_datetime = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_datetime = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    {start_datetime, end_datetime}
  end

  # Get date range for calendar grid display (returns Date values)
  def get_month_date_range(date) do
    first_of_month = Date.beginning_of_month(date)
    last_of_month = Date.end_of_month(date)

    days_since_sunday = Date.day_of_week(first_of_month, :sunday) - 1
    start_date = Date.add(first_of_month, -days_since_sunday)

    days_until_saturday = 7 - Date.day_of_week(last_of_month, :sunday)
    end_date = Date.add(last_of_month, days_until_saturday)

    {start_date, end_date}
  end

  def get_calendar_weeks(date) do
    {start_date, end_date} = get_month_date_range(date)

    start_date
    |> Stream.iterate(&Date.add(&1, 1))
    |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Enum.chunk_every(7)
  end

  def events_for_date(events, date, visible_calendars) do
    events
    |> Enum.filter(fn event ->
      MapSet.member?(visible_calendars, event.calendar_id) and
        (Date.compare(Date.from_iso8601!(Date.to_iso8601(event.dtstart)), date) == :eq or
           (event.dtend && date_in_range?(date, event.dtstart, event.dtend)))
    end)
    |> Enum.sort_by(& &1.dtstart)
  end

  defp date_in_range?(date, start_dt, end_dt) do
    start_date = Date.from_iso8601!(Date.to_iso8601(start_dt))
    end_date = Date.from_iso8601!(Date.to_iso8601(end_dt))
    Date.compare(date, start_date) != :lt and Date.compare(date, end_date) != :gt
  end

  def format_time(nil), do: ""
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  def format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  def month_name(date) do
    Calendar.strftime(date, "%B %Y")
  end

  def day_class(date, current_date, view_date) do
    cond do
      Date.compare(date, current_date) == :eq -> "bg-primary text-primary-content"
      date.month != view_date.month -> "text-base-content/30"
      true -> ""
    end
  end
end
