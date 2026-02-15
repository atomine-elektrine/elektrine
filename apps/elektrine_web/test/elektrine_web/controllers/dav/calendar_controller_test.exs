defmodule ElektrineWeb.DAV.CalendarControllerTest do
  use ElektrineWeb.ConnCase

  alias Elektrine.Accounts
  alias Elektrine.Calendar, as: CalendarContext

  @test_password "testpassword123"

  # Helper to create a test user
  defp create_test_user(attrs \\ %{}) do
    default_attrs = %{
      username: "caluser#{System.unique_integer([:positive])}",
      password: @test_password,
      password_confirmation: @test_password
    }

    {:ok, user} = Accounts.create_user(Map.merge(default_attrs, attrs))
    user
  end

  # Helper to create an authenticated connection using Basic auth
  defp auth_conn(conn, user) do
    encoded = Base.encode64("#{user.username}:#{@test_password}")

    conn
    |> put_req_header("authorization", "Basic #{encoded}")
  end

  describe "propfind_home/2" do
    test "returns calendar home properties", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> request(:propfind, "/calendars/#{user.username}/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ "multistatus"
      assert body =~ "/calendars/#{user.username}/"
    end

    test "returns forbidden for wrong user", %{conn: conn} do
      user = create_test_user()
      other_user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> request(:propfind, "/calendars/#{other_user.username}/")

      assert conn.status == 403
    end

    test "includes calendars at depth 1", %{conn: conn} do
      user = create_test_user()

      # Create a calendar
      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Test Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "1")
        |> request(:propfind, "/calendars/#{user.username}/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ "/calendars/#{user.username}/#{calendar.id}/"
    end
  end

  describe "propfind_calendar/2" do
    test "returns calendar properties", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "My Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "0")
        |> request(:propfind, "/calendars/#{user.username}/#{calendar.id}/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ "multistatus"
      assert body =~ "calendar"
    end

    test "returns 404 for non-existent calendar", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> auth_conn(user)
        |> request(:propfind, "/calendars/#{user.username}/99999/")

      assert conn.status == 404
    end

    test "includes events at depth 1", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Event Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Test Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("depth", "1")
        |> request(:propfind, "/calendars/#{user.username}/#{calendar.id}/")

      assert conn.status == 207
      body = conn.resp_body

      assert body =~ event.uid
    end
  end

  describe "mkcalendar/2" do
    test "creates a new calendar", %{conn: conn} do
      user = create_test_user()

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:set>
          <D:prop>
            <D:displayname>Work Calendar</D:displayname>
          </D:prop>
        </D:set>
      </C:mkcalendar>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:mkcalendar, "/calendars/#{user.username}/work/", body)

      assert conn.status == 201

      # Verify calendar was created
      calendar = CalendarContext.get_calendar_by_name(user.id, "Work Calendar")
      assert calendar != nil
    end

    test "returns 405 if calendar already exists", %{conn: conn} do
      user = create_test_user()

      {:ok, _} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "existing"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:mkcalendar, "/calendars/#{user.username}/existing/", "")

      assert conn.status == 405
    end
  end

  describe "get_event/2" do
    test "returns event as iCalendar", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Get Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Get Test Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      conn =
        conn
        |> auth_conn(user)
        |> get("/calendars/#{user.username}/#{calendar.id}/#{event.uid}.ics")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/calendar"
      body = conn.resp_body

      assert body =~ "BEGIN:VCALENDAR"
      assert body =~ "Get Test Event"
    end

    test "returns 404 for non-existent event", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "404 Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> get("/calendars/#{user.username}/#{calendar.id}/nonexistent.ics")

      assert conn.status == 404
    end
  end

  describe "put_event/2" do
    @valid_icalendar """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:new-event-uid
    DTSTART:20240115T100000Z
    DTEND:20240115T110000Z
    SUMMARY:New Event
    END:VEVENT
    END:VCALENDAR
    """

    test "creates a new event", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Put Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/calendar")
        |> put("/calendars/#{user.username}/#{calendar.id}/new-event-uid.ics", @valid_icalendar)

      assert conn.status == 201
      assert get_resp_header(conn, "etag") != []

      # Verify event was created
      event = CalendarContext.get_event_by_uid(calendar.id, "new-event-uid")
      assert event != nil
      assert event.summary == "New Event"
    end

    test "updates an existing event", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Update Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Original Event",
          uid: "update-event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      updated_icalendar = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:update-event
      DTSTART:20240115T100000Z
      SUMMARY:Updated Event
      END:VEVENT
      END:VCALENDAR
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/calendar")
        |> put_req_header("if-match", "\"#{event.etag}\"")
        |> put("/calendars/#{user.username}/#{calendar.id}/update-event.ics", updated_icalendar)

      assert conn.status == 204

      # Verify event was updated
      updated = CalendarContext.get_event_by_uid(calendar.id, "update-event")
      assert updated.summary == "Updated Event"
    end

    test "returns 412 when If-None-Match * and event exists", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Conflict Calendar"
        })

      {:ok, _event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Existing Event",
          uid: "existing-event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/calendar")
        |> put_req_header("if-none-match", "*")
        |> put("/calendars/#{user.username}/#{calendar.id}/existing-event.ics", @valid_icalendar)

      assert conn.status == 412
    end

    test "returns 400 for invalid iCalendar", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Invalid Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "text/calendar")
        |> put("/calendars/#{user.username}/#{calendar.id}/invalid.ics", "not valid icalendar")

      assert conn.status == 400
    end
  end

  describe "delete_event/2" do
    test "deletes an event", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Delete Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Delete Me",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      conn =
        conn
        |> auth_conn(user)
        |> delete("/calendars/#{user.username}/#{calendar.id}/#{event.uid}.ics")

      assert conn.status == 204

      # Verify event was deleted
      assert CalendarContext.get_event_by_uid(calendar.id, event.uid) == nil
    end

    test "returns 404 for non-existent event", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Delete 404 Calendar"
        })

      conn =
        conn
        |> auth_conn(user)
        |> delete("/calendars/#{user.username}/#{calendar.id}/nonexistent.ics")

      assert conn.status == 404
    end
  end

  describe "report/2" do
    test "handles calendar-multiget", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Multiget Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Multiget Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:prop>
          <D:getetag/>
          <C:calendar-data/>
        </D:prop>
        <D:href>/calendars/#{user.username}/#{calendar.id}/#{event.uid}.ics</D:href>
      </C:calendar-multiget>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/calendars/#{user.username}/#{calendar.id}/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "Multiget Event"
    end

    test "handles calendar-query with time-range", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Query Calendar"
        })

      {:ok, _jan_event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "January Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      {:ok, _feb_event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "February Event",
          dtstart: ~U[2024-02-15 10:00:00Z]
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:prop>
          <D:getetag/>
          <C:calendar-data/>
        </D:prop>
        <C:filter>
          <C:comp-filter name="VCALENDAR">
            <C:comp-filter name="VEVENT">
              <C:time-range start="20240101T000000Z" end="20240131T235959Z"/>
            </C:comp-filter>
          </C:comp-filter>
        </C:filter>
      </C:calendar-query>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/calendars/#{user.username}/#{calendar.id}/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "January Event"
      refute conn.resp_body =~ "February Event"
    end

    test "handles sync-collection", %{conn: conn} do
      user = create_test_user()

      {:ok, calendar} =
        CalendarContext.create_calendar(%{
          user_id: user.id,
          name: "Sync Calendar"
        })

      {:ok, event} =
        CalendarContext.create_event(%{
          calendar_id: calendar.id,
          summary: "Sync Event",
          dtstart: ~U[2024-01-15 10:00:00Z]
        })

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:sync-collection xmlns:D="DAV:">
        <D:sync-token/>
        <D:prop>
          <D:getetag/>
        </D:prop>
      </D:sync-collection>
      """

      conn =
        conn
        |> auth_conn(user)
        |> put_req_header("content-type", "application/xml")
        |> request(:report, "/calendars/#{user.username}/#{calendar.id}/", body)

      assert conn.status == 207
      assert conn.resp_body =~ event.uid
    end
  end

  # Helper to make custom HTTP method requests
  defp request(conn, method, path, body \\ nil) do
    conn =
      if method in [:propfind, :report, :mkcalendar] and !body do
        conn
        |> put_req_header("content-type", "application/xml")
      else
        conn
      end

    body = body || ""

    conn
    |> Phoenix.ConnTest.dispatch(ElektrineWeb.Endpoint, method, path, body)
  end
end
