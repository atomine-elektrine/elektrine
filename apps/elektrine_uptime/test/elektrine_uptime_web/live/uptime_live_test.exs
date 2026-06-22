defmodule ElektrineUptimeWeb.UptimeLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.Uptime

  defp user_fixture do
    username = "u" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 19))

    {:ok, user} =
      Accounts.create_user(%{
        username: username,
        password: "hello world!",
        password_confirmation: "hello world!"
      })

    user
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp monitor_fixture(user, attrs \\ %{}) do
    base = %{
      "name" => "Example monitor",
      "check_type" => "http",
      "target" => "https://example.com",
      "interval_seconds" => 60,
      "failure_threshold" => 2
    }

    {:ok, monitor} = Uptime.create_monitor(user, Map.merge(base, attrs))
    monitor
  end

  setup do
    {:ok, user: user_fixture()}
  end

  test "logged-in user visits /uptime and sees the dashboard", %{conn: conn, user: user} do
    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/uptime")

    assert html =~ "Uptime"
    assert html =~ "Monitors"
  end

  test "seeded monitor name appears in the list", %{conn: conn, user: user} do
    monitor = monitor_fixture(user)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/uptime")

    assert render(view) =~ monitor.name
  end

  test "creating a monitor via the form adds it to the list", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/uptime")

    view
    |> form("#monitor-form", %{
      "monitor" => %{
        "name" => "New HTTP monitor",
        "check_type" => "http",
        "target" => "https://elektrine.com",
        "interval_seconds" => "60",
        "failure_threshold" => "2",
        "expected_status" => "200"
      }
    })
    |> render_submit()

    assert [created] = Uptime.list_monitors(user)
    assert created.name == "New HTTP monitor"
    assert render(view) =~ "New HTTP monitor"
  end

  test "selecting a monitor renders its detail panel", %{conn: conn, user: user} do
    monitor = monitor_fixture(user, %{"name" => "Detail monitor"})

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/uptime?monitor_id=#{monitor.id}")

    html = render(view)
    assert html =~ "Detail monitor"
    assert html =~ "Recent checks"
    assert html =~ "Incidents"
    assert html =~ "Uptime (90 days)"
  end

  test "unauthenticated visitor is redirected", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/uptime")
    assert is_binary(to)
  end
end
