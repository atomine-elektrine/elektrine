defmodule ElektrineWeb.Admin.MonitoringControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias ElektrineWeb.AdminSecurity

  describe "GET /pripyat/active-users" do
    test "includes IMAP-only users in active windows and excludes them from never active", %{
      conn: conn
    } do
      admin = admin_user_fixture()
      imap_user = AccountsFixtures.user_fixture()
      never_active_user = AccountsFixtures.user_fixture()
      imap_user_id = imap_user.id

      recent_access =
        DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second)

      Repo.update_all(
        from(u in User, where: u.id == ^imap_user_id),
        set: [last_imap_access: recent_access, last_login_at: nil, last_pop3_access: nil]
      )

      active_conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/active-users?timeframe=24h")

      active_html = html_response(active_conn, 200)
      assert active_html =~ imap_user.username
      assert active_html =~ "IMAP"

      never_conn =
        conn
        |> recycle()
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/active-users?timeframe=never")

      never_html = html_response(never_conn, 200)
      refute never_html =~ imap_user.username
      assert never_html =~ never_active_user.username
      assert never_html =~ "Never Active"
    end
  end

  describe "GET /pripyat/system-health" do
    test "exposes operational queue pressure and load guard state", %{conn: conn} do
      admin = admin_user_fixture()

      response =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/system-health")
        |> json_response(200)

      assert %{
               "operational" => %{
                 "live" => live,
                 "queue_pressure" => queue_pressure,
                 "load_guard" => load_guard
               }
             } = response

      assert is_map(live)
      assert is_map(queue_pressure)
      assert load_guard["enabled"] in [true, false]
      assert is_integer(load_guard["max_available_or_retryable"])
      assert is_integer(load_guard["available_or_retryable"])
      assert load_guard["overloaded"] in [true, false]
    end
  end

  describe "GET /pripyat/operations" do
    test "renders operational monitoring panels", %{conn: conn} do
      admin = admin_user_fixture()

      html =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/operations")
        |> html_response(200)

      assert html =~ "Operations"
      assert html =~ "Queue Pressure"
      assert html =~ "Live Counters"
      assert html =~ "Media Proxy Cache"
      assert html =~ "Report Outcomes"
      assert html =~ "Skipped Components"
    end

    test "renders current media proxy bans and actions", %{conn: conn} do
      admin = admin_user_fixture()
      url = "https://media.example.com/banned.jpg"
      assert {:ok, _} = Elektrine.MediaProxy.ban(url, :test)

      html =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/operations")
        |> html_response(200)

      assert html =~ "Media Proxy Cache"
      assert html =~ "Runtime bans"
      assert html =~ url
      assert html =~ ~s(action="/pripyat/media-proxy-cache/purge")
      assert html =~ ~s(action="/pripyat/media-proxy-cache/unban")
      assert html =~ ~s(name="_admin_action_grant")
    end
  end

  describe "GET /pripyat/job-queue-stats" do
    test "includes live operational telemetry counters", %{conn: conn} do
      admin = admin_user_fixture()
      before = Elektrine.JobQueueMonitor.stats()
      before_insert = get_in(before, [:home_feed, :fanout_insert]) || 0
      before_skipped = get_in(before, [:federation, :skipped_jobs]) || 0

      :telemetry.execute(
        [:elektrine, :home_feed, :fanout],
        %{count: 1},
        %{operation: :insert, user_id: admin.id, message_id: 1}
      )

      :telemetry.execute(
        [:elektrine, :federation, :load_guard, :skip],
        %{count: 1},
        %{component: :monitoring_test}
      )

      wait_until(fn ->
        stats = Elektrine.JobQueueMonitor.stats()

        (get_in(stats, [:home_feed, :fanout_insert]) || 0) >= before_insert + 1 and
          (get_in(stats, [:federation, :skipped_jobs]) || 0) >= before_skipped + 1
      end)

      response =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/job-queue-stats")
        |> json_response(200)

      assert get_in(response, ["live", "home_feed", "fanout_insert"]) >= before_insert + 1
      assert get_in(response, ["live", "federation", "skipped_jobs"]) >= before_skipped + 1
      assert is_map(response["queue_pressure"])
      assert is_map(response["load_guard"])
    end
  end

  describe "POST /pripyat/media-proxy-cache/unban" do
    test "browser form submissions redirect back to operations", %{conn: conn} do
      admin = admin_user_fixture()
      url = "https://media.example.com/form.jpg"
      request_path = "/pripyat/media-proxy-cache/purge"

      post_conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)
        |> Plug.Conn.put_req_header("accept", "text/html")

      action_grant = AdminSecurity.issue_action_grant(post_conn, admin, "POST", request_path)

      response =
        post(post_conn, request_path, %{
          "urls" => [url],
          "ban" => "true",
          "_admin_action_grant" => action_grant
        })

      assert redirected_to(response) == "/pripyat/operations"
      assert Phoenix.Flash.get(response.assigns.flash, :info) == "Media proxy cache updated."
      assert Elektrine.MediaProxy.runtime_banned?(url)
    end

    test "removes runtime media proxy bans", %{conn: conn} do
      admin = admin_user_fixture()
      url = "https://media.example.com/photo.jpg"

      assert {:ok, _} = Elektrine.MediaProxy.ban(url, :test)

      banned =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/media-proxy-cache")
        |> json_response(200)

      assert Enum.any?(banned["bans"], &(Map.get(&1, "url") == url))

      request_path = "/pripyat/media-proxy-cache/unban"

      post_conn =
        conn
        |> recycle()
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)

      action_grant = AdminSecurity.issue_action_grant(post_conn, admin, "POST", request_path)

      response =
        post_conn
        |> post(request_path, %{"urls" => [url], "_admin_action_grant" => action_grant})
        |> json_response(200)

      assert response["unbanned"] == [url]
      assert response["rejected"] == []
      refute Elektrine.MediaProxy.runtime_banned?(url)
    end
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(fun, 0), do: assert(fun.())
end
