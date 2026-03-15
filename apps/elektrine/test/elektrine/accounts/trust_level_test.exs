defmodule Elektrine.Accounts.TrustLevelTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts.{Moderation, TrustLevel, TrustLevelLog, User, UserActivityStats}
  alias Elektrine.Repo

  import Elektrine.AccountsFixtures

  describe "calculate_trust_level/2" do
    test "uses tracked account and engagement metrics for TL1, TL2, and TL3" do
      tl1_user = backdated_user(%{login_count: 3}, 4)
      tl2_user = backdated_user(%{login_count: 10}, 20)
      tl3_user = backdated_user(%{login_count: 25}, 60)

      assert TrustLevel.calculate_trust_level(tl1_user, %UserActivityStats{
               days_visited: 2,
               topics_entered: 5,
               posts_read: 30,
               time_read_seconds: 600
             }) == 1

      assert TrustLevel.calculate_trust_level(tl2_user, %UserActivityStats{
               days_visited: 15,
               topics_entered: 15,
               posts_read: 100,
               posts_created: 3,
               topics_created: 1,
               replies_created: 3,
               time_read_seconds: 3600,
               likes_given: 3,
               likes_received: 1,
               replies_received: 1
             }) == 2

      assert TrustLevel.calculate_trust_level(tl3_user, %UserActivityStats{
               days_visited: 50,
               topics_entered: 25,
               posts_read: 250,
               posts_created: 10,
               topics_created: 2,
               replies_created: 10,
               likes_given: 15,
               likes_received: 10,
               replies_received: 5
             }) == 3
    end
  end

  describe "change_user_level/3" do
    test "updates the user's level and writes an audit log" do
      user = user_fixture()

      assert {:ok, updated_user} =
               TrustLevel.change_user_level(user, 2,
                 reason: "manual",
                 notes: "Elevated during moderation review"
               )

      assert updated_user.trust_level == 2
      assert updated_user.promoted_at

      log = Repo.one!(from l in TrustLevelLog, where: l.user_id == ^user.id)

      assert log.old_level == 0
      assert log.new_level == 2
      assert log.reason == "manual"
      assert log.notes == "Elevated during moderation review"
    end

    test "records a manual level change after the user row was already updated" do
      user = user_fixture()

      updated_user =
        user
        |> User.admin_changeset(%{username: user.username, trust_level: 3})
        |> Repo.update!()

      assert {:ok, audited_user} =
               TrustLevel.record_level_change(updated_user, user.trust_level,
                 reason: "manual",
                 notes: "Admin adjusted trust level"
               )

      assert audited_user.trust_level == 3
      assert audited_user.promoted_at

      log =
        Repo.one!(from l in TrustLevelLog, where: l.user_id == ^user.id, order_by: [desc: l.id])

      assert log.old_level == 0
      assert log.new_level == 3
      assert log.reason == "manual"
    end
  end

  describe "maybe_auto_promote_user/1" do
    test "promotes an eligible user immediately" do
      user = backdated_user(%{login_count: 10}, 20)

      %UserActivityStats{user_id: user.id}
      |> UserActivityStats.changeset(%{
        days_visited: 15,
        topics_entered: 15,
        posts_read: 100,
        posts_created: 3,
        topics_created: 1,
        replies_created: 3,
        time_read_seconds: 3600,
        likes_given: 3,
        likes_received: 1,
        replies_received: 1
      })
      |> Repo.insert!()

      assert {:ok, promoted_user} = TrustLevel.maybe_auto_promote_user(user.id)
      assert promoted_user.trust_level == 2

      persisted_user = Repo.get!(User, user.id)
      assert persisted_user.trust_level == 2

      log = Repo.one!(from l in TrustLevelLog, where: l.user_id == ^user.id)
      assert log.reason == "automatic"
      assert log.new_level == 2
    end

    test "demotes a user when a suspension penalty is applied" do
      user = backdated_user(%{login_count: 25}, 60)

      %UserActivityStats{user_id: user.id}
      |> UserActivityStats.changeset(%{
        days_visited: 50,
        topics_entered: 25,
        posts_read: 250,
        posts_created: 10,
        topics_created: 2,
        replies_created: 10,
        likes_given: 15,
        likes_received: 10,
        replies_received: 5
      })
      |> Repo.insert!()

      assert {:ok, promoted_user} = TrustLevel.maybe_auto_promote_user(user.id)
      assert promoted_user.trust_level == 3

      suspended_until = DateTime.utc_now() |> DateTime.add(7, :day)

      assert {:ok, suspended_user} =
               Moderation.suspend_user(promoted_user, %{suspended_until: suspended_until})

      assert suspended_user.trust_level == 0
      assert Repo.get_by!(UserActivityStats, user_id: user.id).suspensions_count == 1

      log =
        Repo.one!(
          from l in TrustLevelLog,
            where: l.user_id == ^user.id,
            order_by: [desc: l.id],
            limit: 1
        )

      assert log.old_level == 3
      assert log.new_level == 0
      assert log.reason == "automatic"
    end
  end

  defp backdated_user(extra_attrs, age_in_days) do
    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-age_in_days * 86_400, :second)
      |> DateTime.truncate(:second)

    user_fixture()
    |> Ecto.Changeset.change(Map.put(extra_attrs, :inserted_at, inserted_at))
    |> Repo.update!()
  end
end
