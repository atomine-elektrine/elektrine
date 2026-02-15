defmodule Elektrine.AccountsStatusTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  import Elektrine.AccountsFixtures

  describe "user status updates" do
    setup do
      user = user_fixture()

      %{user: user}
    end

    test "can update user status to online", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "online")
      assert updated_user.status == "online"
      assert updated_user.status_updated_at
    end

    test "can update user status to away", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away")
      assert updated_user.status == "away"
    end

    test "can update user status to dnd", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "dnd")
      assert updated_user.status == "dnd"
    end

    test "can update user status to offline", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "offline")
      assert updated_user.status == "offline"
    end

    test "rejects invalid status values", %{user: user} do
      assert_raise FunctionClauseError, fn ->
        Accounts.update_user_status(user, "invalid_status")
      end
    end

    test "can set status message", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away", "In a meeting")
      assert updated_user.status == "away"
      assert updated_user.status_message == "In a meeting"
    end

    test "sanitizes status message - trims whitespace", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away", "  Busy  ")
      assert updated_user.status_message == "Busy"
    end

    test "sanitizes status message - limits to 100 characters", %{user: user} do
      long_message = String.duplicate("a", 150)
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away", long_message)
      assert String.length(updated_user.status_message) == 100
    end

    test "sets empty status message to nil", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away", "")
      assert is_nil(updated_user.status_message)
    end

    test "sets whitespace-only status message to nil", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away", "   ")
      assert is_nil(updated_user.status_message)
    end

    test "updates status_updated_at timestamp", %{user: user} do
      assert {:ok, updated_user} = Accounts.update_user_status(user, "away")
      assert updated_user.status_updated_at

      # Timestamp should be recent (within last 5 seconds)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, updated_user.status_updated_at, :second)
      assert diff < 5
    end

    test "get_user_status returns status information", %{user: user} do
      {:ok, updated_user} = Accounts.update_user_status(user, "dnd", "Focus time")

      assert {:ok, status_info} = Accounts.get_user_status(updated_user.id)
      assert status_info.status == "dnd"
      assert status_info.message == "Focus time"
      assert status_info.updated_at
    end

    test "get_user_status returns error for non-existent user" do
      assert {:error, :not_found} = Accounts.get_user_status(999_999)
    end
  end

  describe "last_seen_at tracking" do
    setup do
      user = user_fixture()

      %{user: user}
    end

    test "last_seen_at is updated when user connects", %{user: user} do
      # Simulate presence hook updating last_seen
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      query = from u in Elektrine.Accounts.User, where: u.id == ^user.id
      {1, _} = Elektrine.Repo.update_all(query, set: [last_seen_at: now])

      updated_user = Elektrine.Repo.get(Elektrine.Accounts.User, user.id)
      assert updated_user.last_seen_at

      # Check timestamp is close (within 1 second)
      diff = DateTime.diff(updated_user.last_seen_at, now, :second)
      assert abs(diff) <= 1
    end

    test "last_seen_at is preserved after status change", %{user: user} do
      # Set initial last_seen
      past_time = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)
      query = from u in Elektrine.Accounts.User, where: u.id == ^user.id
      {1, _} = Elektrine.Repo.update_all(query, set: [last_seen_at: past_time])

      # Update status
      {:ok, _updated_user} = Accounts.update_user_status(user, "away")

      # Reload user from DB to check last_seen_at was preserved
      reloaded_user = Elektrine.Repo.get(Elektrine.Accounts.User, user.id)

      # last_seen_at should not change (within 1 second tolerance for DB truncation)
      diff = DateTime.diff(reloaded_user.last_seen_at, past_time, :second)
      assert abs(diff) <= 1
    end
  end
end
