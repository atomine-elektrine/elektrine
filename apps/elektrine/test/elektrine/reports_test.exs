defmodule Elektrine.ReportsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.UserActivityStats
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo
  alias Elektrine.Reports

  describe "admin notifications" do
    test "creating a report notifies active admins only" do
      admin = admin_user_fixture()
      non_admin = user_fixture()
      reporter = user_fixture()
      offender = user_fixture()
      post = post_fixture(user: offender)

      assert {:ok, report} =
               Reports.create_report(%{
                 reporter_id: reporter.id,
                 reportable_type: "message",
                 reportable_id: post.id,
                 reason: "spam",
                 priority: "high"
               })

      assert %Notification{} =
               Repo.get_by(Notification,
                 user_id: admin.id,
                 type: "system",
                 source_type: "report",
                 source_id: report.id
               )

      refute Repo.get_by(Notification,
               user_id: non_admin.id,
               type: "system",
               source_type: "report",
               source_id: report.id
             )
    end
  end

  describe "telemetry" do
    setup do
      parent = self()
      handler_id = "reports-test-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:elektrine, :reports, :operation],
          fn event, measurements, metadata, _config ->
            send(parent, {:report_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits report create telemetry" do
      reporter = user_fixture()
      offender = user_fixture()
      post = post_fixture(user: offender)

      assert {:ok, report} =
               Reports.create_report(%{
                 reporter_id: reporter.id,
                 reportable_type: "message",
                 reportable_id: post.id,
                 reason: "spam"
               })

      {[:elektrine, :reports, :operation], %{count: 1}, metadata} =
        assert_receive_report_telemetry("create", %{report_id: Integer.to_string(report.id)})

      assert metadata.operation == "create"
      assert metadata.outcome == "success"
      assert metadata.report_id == Integer.to_string(report.id)
      assert metadata.reportable_type == "message"
    end

    test "emits report action and review telemetry when resolving" do
      admin = admin_user_fixture()
      reporter = user_fixture()
      offender = user_fixture()
      post = post_fixture(user: offender)

      {:ok, report} =
        Reports.create_report(%{
          reporter_id: reporter.id,
          reportable_type: "message",
          reportable_id: post.id,
          reason: "harassment"
        })

      flush_report_telemetry()

      assert {:ok, _updated_report} =
               Reports.resolve_report(report, admin, %{
                 action_taken: "content_removed",
                 resolution_notes: "confirmed"
               })

      {[:elektrine, :reports, :operation], %{count: 1}, action_metadata} =
        assert_receive_report_telemetry("action", %{action: "content_removed"})

      assert action_metadata.operation == "action"
      assert action_metadata.outcome == "success"
      assert action_metadata.action == "content_removed"
      assert action_metadata.reviewer_id == Integer.to_string(admin.id)

      {[:elektrine, :reports, :operation], %{count: 1}, review_metadata} =
        assert_receive_report_telemetry("review", %{status: "resolved"})

      assert review_metadata.operation == "review"
      assert review_metadata.outcome == "success"
      assert review_metadata.status == "resolved"
    end
  end

  describe "trust stats integration" do
    test "creating a report increments reporter and target flag stats" do
      reporter = user_fixture()
      offender = user_fixture()
      post = post_fixture(user: offender)

      assert {:ok, _report} =
               Reports.create_report(%{
                 reporter_id: reporter.id,
                 reportable_type: "message",
                 reportable_id: post.id,
                 reason: "spam"
               })

      assert Repo.get_by!(UserActivityStats, user_id: reporter.id).flags_given == 1
      assert Repo.get_by!(UserActivityStats, user_id: offender.id).flags_received == 1
    end

    test "resolving a report with action increments flags_agreed once" do
      admin = user_fixture()
      reporter = user_fixture()
      offender = user_fixture()
      post = post_fixture(user: offender)

      {:ok, report} =
        Reports.create_report(%{
          reporter_id: reporter.id,
          reportable_type: "message",
          reportable_id: post.id,
          reason: "harassment"
        })

      assert {:ok, updated_report} =
               Reports.review_report(report, %{
                 status: "resolved",
                 action_taken: "content_removed",
                 reviewed_by_id: admin.id
               })

      assert Repo.get_by!(UserActivityStats, user_id: reporter.id).flags_agreed == 1

      assert {:ok, _report} =
               Reports.review_report(updated_report, %{
                 resolution_notes: "confirmed by moderator",
                 reviewed_by_id: admin.id
               })

      assert Repo.get_by!(UserActivityStats, user_id: reporter.id).flags_agreed == 1
    end
  end

  defp admin_user_fixture do
    user = user_fixture()
    {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
    admin
  end

  defp flush_report_telemetry do
    receive do
      {:report_telemetry, _, _, _} -> flush_report_telemetry()
    after
      10 -> :ok
    end
  end

  defp assert_receive_report_telemetry(operation, filters) do
    receive do
      {:report_telemetry, event, measurements, metadata} ->
        if metadata.operation == operation and telemetry_metadata_matches?(metadata, filters) do
          {event, measurements, metadata}
        else
          assert_receive_report_telemetry(operation, filters)
        end
    after
      500 ->
        flunk("expected report telemetry for #{operation} with #{inspect(filters)}")
    end
  end

  defp telemetry_metadata_matches?(metadata, filters) do
    Enum.all?(filters, fn {key, value} -> Map.get(metadata, key) == value end)
  end
end
