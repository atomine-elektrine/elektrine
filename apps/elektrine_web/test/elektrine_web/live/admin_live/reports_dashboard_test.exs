defmodule ElektrineWeb.AdminLive.ReportsDashboardTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Reports
  alias Elektrine.SocialFixtures

  test "opens reported users in the admin edit flow", %{conn: conn} do
    admin = admin_user_fixture()
    reported_user = AccountsFixtures.user_fixture()
    reporter = AccountsFixtures.user_fixture()

    {:ok, report} =
      Reports.create_report(%{
        reporter_id: reporter.id,
        reportable_type: "user",
        reportable_id: reported_user.id,
        reason: "harassment"
      })

    {:ok, view, _html} =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> live(~p"/pripyat/reports")

    view
    |> element(
      "table button[phx-click='view_reported_item'][phx-value-type='user'][phx-value-id='#{report.reportable_id}']"
    )
    |> render_click()

    assert_redirect(view, "/pripyat/users/#{reported_user.id}/edit")
  end

  test "delete_message removes the reported post and resolves the report", %{conn: conn} do
    admin = admin_user_fixture()
    reporter = AccountsFixtures.user_fixture()
    offender = AccountsFixtures.user_fixture()
    post = SocialFixtures.post_fixture(user: offender)

    {:ok, report} =
      Reports.create_report(%{
        reporter_id: reporter.id,
        reportable_type: "message",
        reportable_id: post.id,
        reason: "spam"
      })

    {:ok, view, _html} =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> live(~p"/pripyat/reports")

    view
    |> element("table button[phx-click='view_report'][phx-value-id='#{report.id}']")
    |> render_click()

    view
    |> element(
      "button[phx-click='admin_action'][phx-value-action='delete_message'][phx-value-message_id='#{post.id}']"
    )
    |> render_click()

    updated_report = Reports.get_report!(report.id)
    deleted_post = Repo.get!(Message, post.id)

    assert updated_report.status == "resolved"
    assert updated_report.action_taken == "content_removed"
    assert updated_report.reviewed_by_id == admin.id
    assert deleted_post.deleted_at
    assert render(view) =~ "Message deleted"
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "elektrine.com")
  end

  defp log_in_as(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)
    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
