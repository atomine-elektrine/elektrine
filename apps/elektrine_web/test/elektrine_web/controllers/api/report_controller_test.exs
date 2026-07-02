defmodule ElektrineWeb.API.ReportControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures
  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.AuditLog
  alias Elektrine.Developer
  alias Elektrine.Repo
  alias Elektrine.Reports
  alias Elektrine.Reports.Report
  alias Elektrine.Social.Message
  alias ElektrineWeb.API.ReportController

  describe "create/2" do
    test "returns target account metadata for account reports", %{conn: conn} do
      reporter = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> assign(:current_user, reporter)
        |> ReportController.create(%{
          "account_id" => to_string(target.id),
          "reason" => "spam",
          "comment" => "reported through controller test"
        })

      assert %{
               "status" => "pending",
               "target_account_id" => target_account_id
             } = json_response(conn, 201)

      assert target_account_id == to_string(target.id)
    end
  end

  describe "index/2" do
    test "lists only the current user's reports for regular users", %{conn: conn} do
      reporter = user_fixture()
      other_reporter = user_fixture()
      target = user_fixture()

      {:ok, report} = report_fixture(reporter, target, %{reason: "spam"})
      {:ok, _other_report} = report_fixture(other_reporter, target, %{reason: "harassment"})

      conn =
        conn
        |> assign(:current_user, reporter)
        |> ReportController.index(%{})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(report.id)
    end

    test "lists all reports for admins", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      other_reporter = user_fixture()
      target = user_fixture()

      {:ok, first_report} = report_fixture(reporter, target, %{reason: "spam"})
      {:ok, second_report} = report_fixture(other_reporter, target, %{reason: "harassment"})

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.index(%{})

      ids =
        conn
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert to_string(first_report.id) in ids
      assert to_string(second_report.id) in ids
    end

    test "paginates admin report lists", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      first_target = user_fixture()
      second_target = user_fixture()

      {:ok, _first_report} = report_fixture(reporter, first_target, %{reason: "spam"})
      {:ok, _second_report} = report_fixture(reporter, second_target, %{reason: "harassment"})

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.index(%{"page" => "1", "per_page" => "1"})

      assert [_report] = json_response(conn, 200)
      assert get_resp_header(conn, "x-total-count") == ["2"]
      assert get_resp_header(conn, "x-page") == ["1"]
      assert get_resp_header(conn, "x-per-page") == ["1"]
      assert get_resp_header(conn, "x-total-pages") == ["2"]
    end
  end

  describe "scoped routes" do
    test "requires moderation read scope for PAT report listing", %{conn: conn} do
      admin = admin_user_fixture()

      conn =
        conn
        |> with_pat(admin.id, ["read:account"])
        |> get("/api/v1/reports")

      assert %{"error" => %{"code" => "insufficient_scope"}} = json_response(conn, 403)
    end

    test "allows moderation read PATs to list reports", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> with_pat(admin.id, ["read:moderation"])
        |> get("/api/v1/reports", %{"per_page" => "1"})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(report.id)
      assert get_resp_header(conn, "x-total-count") == ["1"]
    end

    test "requires moderation write scope for PAT report actions", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> with_pat(admin.id, ["read:moderation"])
        |> post("/api/v1/reports/#{report.id}/resolve", %{"action_taken" => "warned"})

      assert %{"error" => %{"code" => "insufficient_scope"}} = json_response(conn, 403)
    end

    test "allows moderation write PATs to resolve reports", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> with_pat(admin.id, ["write:moderation"])
        |> post("/api/v1/reports/#{report.id}/resolve", %{"action_taken" => "warned"})

      assert %{"status" => "resolved", "action_taken_type" => "warned"} = json_response(conn, 200)
    end

    test "allows social write PATs to create reports", %{conn: conn} do
      reporter = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> with_pat(reporter.id, ["write:social"])
        |> post("/api/v1/reports", %{
          "account_id" => to_string(target.id),
          "reason" => "spam",
          "comment" => "reported through scoped route test"
        })

      assert %{
               "status" => "pending",
               "target_account_id" => target_account_id
             } = json_response(conn, 201)

      assert target_account_id == to_string(target.id)
    end
  end

  describe "show/2" do
    test "hides another user's report from regular users", %{conn: conn} do
      viewer = user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> ReportController.show(%{"id" => to_string(report.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "shows any report to admins", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.show(%{"id" => to_string(report.id)})

      assert %{"id" => id, "status" => "pending"} = json_response(conn, 200)
      assert id == to_string(report.id)
    end
  end

  describe "update/2" do
    test "lets admins update report status and priority", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.update(%{
          "id" => to_string(report.id),
          "status" => "reviewing",
          "priority" => "critical",
          "resolution_notes" => "needs review"
        })

      assert %{
               "status" => "reviewing",
               "priority" => "critical",
               "reviewed_by_id" => reviewed_by_id,
               "resolution_notes" => "needs review"
             } = json_response(conn, 200)

      assert reviewed_by_id == to_string(admin.id)

      updated_report = Repo.get!(Report, report.id)
      assert updated_report.status == "reviewing"
      assert updated_report.priority == "critical"
      assert updated_report.reviewed_by_id == admin.id

      log = latest_audit_log(admin.id, report.id, "report.update")
      assert log.target_user_id == target.id
      assert log.details["status_from"] == "pending"
      assert log.details["status_to"] == "reviewing"
      assert log.details["priority_from"] == "normal"
      assert log.details["priority_to"] == "critical"
    end

    test "rejects regular users", %{conn: conn} do
      user = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(user, target)

      conn =
        conn
        |> assign(:current_user, user)
        |> ReportController.update(%{"id" => to_string(report.id), "status" => "resolved"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end
  end

  describe "resolve/2, dismiss/2, and reopen/2" do
    test "resolves a report with action metadata", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.resolve(%{
          "id" => to_string(report.id),
          "action_taken" => "warned",
          "resolution_notes" => "warning sent"
        })

      assert %{
               "status" => "resolved",
               "action_taken" => true,
               "action_taken_type" => "warned",
               "resolution_notes" => "warning sent"
             } = json_response(conn, 200)

      updated_report = Repo.get!(Report, report.id)
      assert updated_report.status == "resolved"
      assert updated_report.action_taken == "warned"
      assert updated_report.reviewed_by_id == admin.id
      assert updated_report.reviewed_at

      log = latest_audit_log(admin.id, report.id, "report.resolve")
      assert log.target_user_id == target.id
      assert log.details["action_taken_from"] == nil
      assert log.details["action_taken_to"] == "warned"
    end

    test "content_removed deletes the reported message", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      post = post_fixture(%{user: target})

      {:ok, report} =
        Reports.create_report(%{
          reporter_id: reporter.id,
          reportable_type: "message",
          reportable_id: post.id,
          reason: "spam",
          description: "remove this"
        })

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.resolve(%{
          "id" => to_string(report.id),
          "action_taken" => "content_removed",
          "resolution_notes" => "removed"
        })

      assert %{"status" => "resolved", "action_taken_type" => "content_removed"} =
               json_response(conn, 200)

      assert Repo.get!(Message, post.id).deleted_at
    end

    test "suspended suspends the reported user", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.resolve(%{
          "id" => to_string(report.id),
          "action_taken" => "suspended"
        })

      assert %{"status" => "resolved", "action_taken_type" => "suspended"} =
               json_response(conn, 200)

      target = Accounts.get_user!(target.id)
      assert target.suspended
      assert target.suspended_until
      assert target.suspension_reason == "Suspended via report ##{report.id}"
    end

    test "banned bans the reported user", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.resolve(%{
          "id" => to_string(report.id),
          "action_taken" => "banned"
        })

      assert %{"status" => "resolved", "action_taken_type" => "banned"} =
               json_response(conn, 200)

      target = Accounts.get_user!(target.id)
      assert target.banned
      assert target.banned_reason == "Banned via report ##{report.id}"
    end

    test "content_removed rejects non-message reports without resolving", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.resolve(%{
          "id" => to_string(report.id),
          "action_taken" => "content_removed"
        })

      assert %{"error" => "unsupported_report_target"} = json_response(conn, 422)
      assert Repo.get!(Report, report.id).status == "pending"
    end

    test "dismisses a report with no action by default", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.dismiss(%{"id" => to_string(report.id)})

      assert %{"status" => "dismissed", "action_taken_type" => "no_action"} =
               json_response(conn, 200)

      updated_report = Repo.get!(Report, report.id)
      assert updated_report.status == "dismissed"
      assert updated_report.action_taken == "no_action"

      log = latest_audit_log(admin.id, report.id, "report.dismiss")
      assert log.target_user_id == target.id
      assert log.details["status_from"] == "pending"
      assert log.details["status_to"] == "dismissed"
    end

    test "reopens a reviewed report and clears review metadata", %{conn: conn} do
      admin = admin_user_fixture()
      reporter = user_fixture()
      target = user_fixture()
      {:ok, report} = report_fixture(reporter, target)

      {:ok, resolved_report} =
        Reports.review_report(report, %{
          status: "resolved",
          reviewed_by_id: admin.id,
          action_taken: "warned",
          resolution_notes: "warning sent"
        })

      conn =
        conn
        |> assign(:current_user, admin)
        |> ReportController.reopen(%{"id" => to_string(resolved_report.id)})

      assert %{
               "status" => "pending",
               "action_taken" => false,
               "action_taken_type" => nil,
               "resolution_notes" => nil,
               "reviewed_by_id" => nil
             } = json_response(conn, 200)

      updated_report = Repo.get!(Report, report.id)
      assert updated_report.status == "pending"
      refute updated_report.action_taken
      refute updated_report.resolution_notes
      refute updated_report.reviewed_by_id
      refute updated_report.reviewed_at

      log = latest_audit_log(admin.id, report.id, "report.reopen")
      assert log.target_user_id == target.id
      assert log.details["status_from"] == "resolved"
      assert log.details["status_to"] == "pending"
      assert log.details["action_taken_from"] == "warned"
      assert log.details["action_taken_to"] == nil
    end
  end

  defp admin_user_fixture do
    user = user_fixture()
    {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
    admin
  end

  defp report_fixture(reporter, target, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          reporter_id: reporter.id,
          reportable_type: "user",
          reportable_id: target.id,
          reason: "other",
          description: "reported through API test"
        },
        attrs
      )

    Reports.create_report(attrs)
  end

  defp with_pat(conn, user_id, scopes) do
    {:ok, token} =
      Developer.create_api_token(user_id, %{
        name: "report-test-token-#{System.unique_integer([:positive])}",
        scopes: scopes
      })

    put_req_header(conn, "authorization", "Bearer #{token.token}")
  end

  defp latest_audit_log(admin_id, report_id, action) do
    Repo.one!(
      from(a in AuditLog,
        where:
          a.admin_id == ^admin_id and
            a.action == ^action and
            a.resource_type == "report" and
            a.resource_id == ^report_id,
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end
end
