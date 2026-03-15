defmodule Elektrine.ReportsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts.UserActivityStats
  alias Elektrine.Repo
  alias Elektrine.Reports

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
end
