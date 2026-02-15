defmodule Elektrine.CalendarTest do
  use Elektrine.DataCase

  alias Elektrine.Calendar, as: CalendarContext
  alias Elektrine.Accounts

  # Helper to create a test user
  defp create_test_user(attrs \\ %{}) do
    default_attrs = %{
      username: "testuser#{System.unique_integer([:positive])}",
      password: "testpassword123",
      password_confirmation: "testpassword123"
    }

    {:ok, user} = Accounts.create_user(Map.merge(default_attrs, attrs))
    user
  end

  describe "calendars" do
    test "list_calendars/1 returns empty list for user with no calendars" do
      user = create_test_user()
      assert [] == CalendarContext.list_calendars(user.id)
    end

    test "create_calendar/1 creates a calendar" do
      user = create_test_user()

      attrs = %{
        user_id: user.id,
        name: "My Calendar",
        color: "#ff0000",
        description: "Test calendar"
      }

      assert {:ok, calendar} = CalendarContext.create_calendar(attrs)
      assert calendar.name == "My Calendar"
      assert calendar.color == "#ff0000"
      assert calendar.description == "Test calendar"
      assert calendar.user_id == user.id
      assert calendar.ctag != nil
    end

    test "list_calendars/1 returns all calendars for a user" do
      user = create_test_user()

      {:ok, _cal1} = CalendarContext.create_calendar(%{user_id: user.id, name: "Calendar 1"})
      {:ok, _cal2} = CalendarContext.create_calendar(%{user_id: user.id, name: "Calendar 2"})

      calendars = CalendarContext.list_calendars(user.id)
      assert length(calendars) == 2
    end

    test "get_calendar!/1 returns the calendar" do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "Test"})

      fetched = CalendarContext.get_calendar!(calendar.id)
      assert fetched.id == calendar.id
      assert fetched.name == "Test"
    end

    test "get_calendar_by_name/2 returns calendar by name" do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "Work"})

      fetched = CalendarContext.get_calendar_by_name(user.id, "Work")
      assert fetched.id == calendar.id
    end

    test "get_or_create_default_calendar/1 creates default if none exists" do
      user = create_test_user()

      assert {:ok, calendar} = CalendarContext.get_or_create_default_calendar(user.id)
      assert calendar.name == "Default"
      assert calendar.is_default == true
    end

    test "get_or_create_default_calendar/1 returns existing default" do
      user = create_test_user()

      {:ok, first} = CalendarContext.get_or_create_default_calendar(user.id)
      {:ok, second} = CalendarContext.get_or_create_default_calendar(user.id)

      assert first.id == second.id
    end

    test "update_calendar/2 updates the calendar" do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "Original"})

      assert {:ok, updated} = CalendarContext.update_calendar(calendar, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "update_calendar/2 updates ctag" do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "Test"})
      original_ctag = calendar.ctag

      # Sleep for at least 1 second since ctag uses Unix timestamps (second precision)
      Process.sleep(1100)

      {:ok, updated} = CalendarContext.update_calendar(calendar, %{name: "Updated"})
      assert updated.ctag != original_ctag
    end

    test "delete_calendar/1 deletes the calendar" do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "ToDelete"})

      assert {:ok, _} = CalendarContext.delete_calendar(calendar)
      assert_raise Ecto.NoResultsError, fn -> CalendarContext.get_calendar!(calendar.id) end
    end

    test "create_calendar/1 enforces unique name per user" do
      user = create_test_user()
      {:ok, _} = CalendarContext.create_calendar(%{user_id: user.id, name: "Same Name"})

      assert {:error, changeset} =
               CalendarContext.create_calendar(%{user_id: user.id, name: "Same Name"})

      # Unique constraint on [:user_id, :name] reports error on first field
      assert errors_on(changeset).user_id != nil
    end
  end

  describe "events" do
    setup do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{user_id: user.id, name: "Test Calendar"})

      %{user: user, calendar: calendar}
    end

    test "create_event/1 creates an event", %{calendar: calendar} do
      attrs = %{
        calendar_id: calendar.id,
        summary: "Test Event",
        dtstart: ~U[2024-01-15 10:00:00Z],
        dtend: ~U[2024-01-15 11:00:00Z]
      }

      assert {:ok, event} = CalendarContext.create_event(attrs)
      assert event.summary == "Test Event"
      assert event.uid != nil
      assert event.etag != nil
    end

    test "list_events/1 returns all events in calendar", %{calendar: calendar} do
      {:ok, _} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Event 1",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      {:ok, _} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Event 2",
          dtstart: ~U[2024-01-16 10:00:00Z]
        })

      events = CalendarContext.list_events(calendar.id)
      assert length(events) == 2
    end

    test "list_events_in_range/3 filters by date range", %{calendar: calendar} do
      {:ok, _} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "January Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      {:ok, _} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "February Event",
          dtstart: ~U[2024-02-15 10:00:00Z]
        })

      jan_events =
        CalendarContext.list_events_in_range(
          calendar.id,
          ~U[2024-01-01 00:00:00Z],
          ~U[2024-01-31 23:59:59Z]
        )

      assert length(jan_events) == 1
      assert hd(jan_events).summary == "January Event"
    end

    test "get_event_by_uid/2 returns event by UID", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Find Me",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      found = CalendarContext.get_event_by_uid(calendar.id, event.uid)
      assert found.id == event.id
    end

    test "update_event/2 updates the event", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Original",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      assert {:ok, updated} = CalendarContext.update_event(event, %{summary: "Updated"})
      assert updated.summary == "Updated"
    end

    test "update_event/2 updates calendar ctag", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Test",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      original_ctag = CalendarContext.get_calendar!(calendar.id).ctag

      # Sleep for at least 1 second since ctag uses Unix timestamps (second precision)
      Process.sleep(1100)

      {:ok, _} = CalendarContext.update_event(event, %{summary: "Updated"})
      updated_ctag = CalendarContext.get_calendar!(calendar.id).ctag

      assert updated_ctag != original_ctag
    end

    test "delete_event/1 deletes the event", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Delete Me",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      assert {:ok, _} = CalendarContext.delete_event(event)
      assert CalendarContext.get_event_by_uid(calendar.id, event.uid) == nil
    end

    test "delete_event/1 updates calendar ctag", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Delete Me",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      original_ctag = CalendarContext.get_calendar!(calendar.id).ctag

      # Sleep for at least 1 second since ctag uses Unix timestamps (second precision)
      Process.sleep(1100)

      {:ok, _} = CalendarContext.delete_event(event)
      updated_ctag = CalendarContext.get_calendar!(calendar.id).ctag

      assert updated_ctag != original_ctag
    end
  end

  describe "CalDAV operations" do
    setup do
      user = create_test_user()
      {:ok, calendar} = CalendarContext.create_calendar(%{user_id: user.id, name: "CalDAV Test"})
      %{user: user, calendar: calendar}
    end

    test "upsert_event_from_icalendar/3 creates new event", %{calendar: calendar} do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:caldav-test@example.com
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      SUMMARY:CalDAV Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} =
               CalendarContext.upsert_event_from_icalendar(
                 calendar.id,
                 "caldav-test@example.com",
                 icalendar
               )

      assert event.uid == "caldav-test@example.com"
      assert event.summary == "CalDAV Event"
      assert event.icalendar_data == icalendar
    end

    test "upsert_event_from_icalendar/3 updates existing event", %{calendar: calendar} do
      icalendar1 = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:update-test@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Original
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, _} =
        CalendarContext.upsert_event_from_icalendar(
          calendar.id,
          "update-test@example.com",
          icalendar1
        )

      icalendar2 = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:update-test@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Updated
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} =
               CalendarContext.upsert_event_from_icalendar(
                 calendar.id,
                 "update-test@example.com",
                 icalendar2
               )

      assert event.summary == "Updated"
    end

    test "list_events_since/2 returns events modified since timestamp", %{calendar: calendar} do
      {:ok, _old} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Old Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      # Capture 'since' timestamp and truncate to seconds (database precision)
      since = DateTime.utc_now() |> DateTime.truncate(:second)

      # Wait at least 1 second so new event has updated_at > since
      Process.sleep(1100)

      {:ok, _new} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "New Event",
          dtstart: ~U[2024-01-16 10:00:00Z]
        })

      recent = CalendarContext.list_events_since(calendar.id, since)
      assert length(recent) == 1
      assert hd(recent).summary == "New Event"
    end

    test "ensure_icalendar_data/1 generates icalendar if missing", %{calendar: calendar} do
      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "No iCal",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      ical = CalendarContext.ensure_icalendar_data(event)
      assert String.contains?(ical, "BEGIN:VCALENDAR")
      assert String.contains?(ical, "SUMMARY:No iCal")
    end
  end
end
