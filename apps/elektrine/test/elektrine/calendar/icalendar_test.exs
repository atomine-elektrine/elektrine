defmodule Elektrine.Calendar.ICalendarTest do
  use ExUnit.Case, async: true

  alias Elektrine.Calendar.ICalendar

  describe "parse/1" do
    test "parses a simple event" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:test-event@example.com
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      SUMMARY:Test Meeting
      DESCRIPTION:A test event
      LOCATION:Conference Room A
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.uid == "test-event@example.com"
      assert event.summary == "Test Meeting"
      assert event.description == "A test event"
      assert event.location == "Conference Room A"
      assert event.dtstart.hour == 10
      assert event.dtstart.minute == 0
    end

    test "parses all-day events" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:allday@example.com
      DTSTART;VALUE=DATE:20240120
      DTEND;VALUE=DATE:20240121
      SUMMARY:All Day Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.uid == "allday@example.com"
      assert event.all_day == true
      assert event.dtstart.year == 2024
      assert event.dtstart.month == 1
      assert event.dtstart.day == 20
    end

    test "parses event with timezone" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:tz@example.com
      DTSTART;TZID=America/New_York:20240115T100000
      DTEND;TZID=America/New_York:20240115T110000
      SUMMARY:TZ Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.timezone == "America/New_York"
    end

    test "parses event with recurrence rule" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:recur@example.com
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      SUMMARY:Weekly Meeting
      RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.rrule == "FREQ=WEEKLY;BYDAY=MO;COUNT=10"
    end

    test "parses event with attendees" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:attendee@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Team Meeting
      ORGANIZER;CN=Boss:mailto:boss@example.com
      ATTENDEE;CN=Employee;PARTSTAT=ACCEPTED:mailto:emp@example.com
      ATTENDEE;CN=Guest;PARTSTAT=TENTATIVE;RSVP=TRUE:mailto:guest@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.organizer["email"] == "boss@example.com"
      assert event.organizer["cn"] == "Boss"
      assert length(event.attendees) == 2

      emp = Enum.find(event.attendees, &(&1["email"] == "emp@example.com"))
      assert emp["partstat"] == "ACCEPTED"

      guest = Enum.find(event.attendees, &(&1["email"] == "guest@example.com"))
      assert guest["partstat"] == "TENTATIVE"
      assert guest["rsvp"] == true
    end

    test "parses event with status and classification" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:status@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Private Meeting
      STATUS:TENTATIVE
      CLASS:PRIVATE
      TRANSP:TRANSPARENT
      PRIORITY:1
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.status == "TENTATIVE"
      assert event.classification == "PRIVATE"
      assert event.transparency == "TRANSPARENT"
      assert event.priority == 1
    end

    test "parses event with categories" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:cats@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Categorized Event
      CATEGORIES:Work,Important,Project
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.categories == ["Work", "Important", "Project"]
    end

    test "parses event with escaped characters" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:escape@example.com
      DTSTART:20240115T100000Z
      SUMMARY:Meeting\\, Important
      DESCRIPTION:Line 1\\nLine 2\\;semicolon
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.summary == "Meeting, Important"
      assert event.description == "Line 1\nLine 2;semicolon"
    end

    test "handles folded lines" do
      icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:fold@example.com
      DTSTART:20240115T100000Z
      SUMMARY:This is a very long summary that continues
       on the next line
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = ICalendar.parse(icalendar)
      assert event.summary == "This is a very long summary that continueson the next line"
    end

    test "returns error for invalid iCalendar" do
      assert {:error, :no_vevent_found} = ICalendar.parse("not a valid icalendar")
    end
  end

  describe "generate/1" do
    test "generates a simple event" do
      event = %{
        uid: "gen-test@example.com",
        summary: "Generated Event",
        dtstart: ~U[2024-01-15 10:00:00Z],
        dtend: ~U[2024-01-15 11:00:00Z]
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "BEGIN:VCALENDAR")
      assert String.contains?(icalendar, "VERSION:2.0")
      assert String.contains?(icalendar, "BEGIN:VEVENT")
      assert String.contains?(icalendar, "UID:gen-test@example.com")
      assert String.contains?(icalendar, "SUMMARY:Generated Event")
      assert String.contains?(icalendar, "DTSTART:20240115T100000Z")
      assert String.contains?(icalendar, "DTEND:20240115T110000Z")
      assert String.contains?(icalendar, "END:VEVENT")
      assert String.contains?(icalendar, "END:VCALENDAR")
    end

    test "generates all-day event" do
      event = %{
        uid: "allday-gen@example.com",
        summary: "All Day",
        dtstart: ~U[2024-01-20 00:00:00Z],
        dtend: ~U[2024-01-21 00:00:00Z],
        all_day: true
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "DTSTART;VALUE=DATE:20240120")
      assert String.contains?(icalendar, "DTEND;VALUE=DATE:20240121")
    end

    test "generates event with recurrence" do
      event = %{
        uid: "recur-gen@example.com",
        summary: "Weekly",
        dtstart: ~U[2024-01-15 10:00:00Z],
        rrule: "FREQ=WEEKLY;COUNT=4"
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "RRULE:FREQ=WEEKLY;COUNT=4")
    end

    test "generates event with location and description" do
      event = %{
        uid: "loc-gen@example.com",
        summary: "Meeting",
        dtstart: ~U[2024-01-15 10:00:00Z],
        location: "Room 101",
        description: "Important discussion"
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "LOCATION:Room 101")
      assert String.contains?(icalendar, "DESCRIPTION:Important discussion")
    end

    test "generates event with attendees" do
      event = %{
        uid: "att-gen@example.com",
        summary: "Team Sync",
        dtstart: ~U[2024-01-15 10:00:00Z],
        organizer: %{"email" => "boss@example.com", "cn" => "Boss"},
        attendees: [
          %{"email" => "emp1@example.com", "cn" => "Employee 1", "partstat" => "ACCEPTED"},
          %{"email" => "emp2@example.com", "partstat" => "NEEDS-ACTION", "rsvp" => true}
        ]
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "ORGANIZER;CN=Boss:mailto:boss@example.com")
      assert String.contains?(icalendar, "ATTENDEE")
      # After line folding, emails may be split across lines
      # Check unfolded content
      unfolded = String.replace(icalendar, ~r/\r\n /, "")
      assert String.contains?(unfolded, "emp1@example.com")
      assert String.contains?(unfolded, "emp2@example.com")
    end

    test "generates event with alarm" do
      event = %{
        uid: "alarm-gen@example.com",
        summary: "Reminder Test",
        dtstart: ~U[2024-01-15 10:00:00Z],
        alarms: [
          %{"action" => "DISPLAY", "trigger" => "-PT15M", "description" => "Meeting soon"}
        ]
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "BEGIN:VALARM")
      assert String.contains?(icalendar, "ACTION:DISPLAY")
      assert String.contains?(icalendar, "TRIGGER:-PT15M")
      assert String.contains?(icalendar, "END:VALARM")
    end

    test "escapes special characters" do
      event = %{
        uid: "escape-gen@example.com",
        summary: "Meeting, Important",
        description: "Line 1\nLine 2;semicolon",
        dtstart: ~U[2024-01-15 10:00:00Z]
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "SUMMARY:Meeting\\, Important")
      assert String.contains?(icalendar, "DESCRIPTION:Line 1\\nLine 2\\;semicolon")
    end

    test "generates unique UID if not provided" do
      event = %{
        summary: "No UID",
        dtstart: ~U[2024-01-15 10:00:00Z]
      }

      assert {:ok, icalendar} = ICalendar.generate(event)
      assert String.contains?(icalendar, "UID:")
      assert String.contains?(icalendar, "@elektrine.com")
    end
  end

  describe "generate_uid/0" do
    test "generates unique UIDs" do
      uid1 = ICalendar.generate_uid()
      uid2 = ICalendar.generate_uid()

      assert uid1 != uid2
      assert String.ends_with?(uid1, "@elektrine.com")
    end
  end

  describe "generate_etag/1" do
    test "generates consistent etag for same event" do
      event = %{uid: "test", sequence: 1, updated_at: ~U[2024-01-15 10:00:00Z]}

      etag1 = ICalendar.generate_etag(event)
      etag2 = ICalendar.generate_etag(event)

      assert etag1 == etag2
    end

    test "generates different etag when event changes" do
      event1 = %{uid: "test", sequence: 1, updated_at: ~U[2024-01-15 10:00:00Z]}
      event2 = %{uid: "test", sequence: 2, updated_at: ~U[2024-01-15 11:00:00Z]}

      etag1 = ICalendar.generate_etag(event1)
      etag2 = ICalendar.generate_etag(event2)

      assert etag1 != etag2
    end
  end

  describe "round-trip parsing and generation" do
    test "parse then generate preserves data" do
      original = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:roundtrip@example.com
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      SUMMARY:Round Trip Test
      DESCRIPTION:Testing round trip
      LOCATION:Test Location
      STATUS:CONFIRMED
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, parsed} = ICalendar.parse(original)
      assert {:ok, generated} = ICalendar.generate(parsed)
      assert {:ok, reparsed} = ICalendar.parse(generated)

      assert reparsed.uid == "roundtrip@example.com"
      assert reparsed.summary == "Round Trip Test"
      assert reparsed.description == "Testing round trip"
      assert reparsed.location == "Test Location"
      assert reparsed.status == "CONFIRMED"
    end
  end
end
