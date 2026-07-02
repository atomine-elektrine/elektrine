defmodule Elektrine.Accounts.MutingTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.UserMute
  alias Elektrine.Repo

  describe "mute_user/3 and unmute_user/2" do
    test "mutes and unmutes users" do
      user = user_fixture()
      target = user_fixture()

      assert {:ok, mute} = Accounts.mute_user(user.id, target.id, false)
      refute mute.mute_notifications
      assert Accounts.user_muted?(user.id, target.id)
      refute Accounts.user_muting_notifications?(user.id, target.id)

      assert {:ok, _mute} = Accounts.unmute_user(user.id, target.id)
      refute Accounts.user_muted?(user.id, target.id)
    end

    test "updates existing mute notification preference" do
      user = user_fixture()
      target = user_fixture()

      assert {:ok, _mute} = Accounts.mute_user(user.id, target.id, false)
      refute Accounts.user_muting_notifications?(user.id, target.id)

      assert {:ok, updated} = Accounts.mute_user(user.id, target.id, true)
      assert updated.mute_notifications
      assert Accounts.user_muting_notifications?(user.id, target.id)
    end

    test "cannot mute yourself" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.mute_user(user.id, user.id, false)
      assert "cannot mute yourself" in errors_on(changeset).muted_id
    end

    test "unmuting a non-muted user returns not_muted" do
      user = user_fixture()
      target = user_fixture()

      assert {:error, :not_muted} = Accounts.unmute_user(user.id, target.id)
    end

    test "temporary mutes expire on read" do
      user = user_fixture()
      target = user_fixture()
      expires_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      assert {:ok, mute} = Accounts.mute_user(user.id, target.id, true, expires_at)
      assert mute.expires_at == expires_at

      refute Accounts.user_muted?(user.id, target.id)
      assert {:error, :not_muted} = Accounts.unmute_user(user.id, target.id)
    end

    test "future temporary mutes remain active" do
      user = user_fixture()
      target = user_fixture()

      assert {:ok, mute} = Accounts.mute_user(user.id, target.id, true, 3600)
      assert mute.expires_at
      assert Accounts.user_muted?(user.id, target.id)
      assert Accounts.user_muting_notifications?(user.id, target.id)
    end

    test "expire_due_mutes removes all due mutes" do
      user = user_fixture()
      target = user_fixture()
      other = user_fixture()

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      %UserMute{}
      |> UserMute.changeset(%{muter_id: user.id, muted_id: target.id, expires_at: past})
      |> Repo.insert!()

      %UserMute{}
      |> UserMute.changeset(%{muter_id: user.id, muted_id: other.id, expires_at: future})
      |> Repo.insert!()

      assert Accounts.expire_due_mutes() == 1
      refute Accounts.user_muted?(user.id, target.id)
      assert Accounts.user_muted?(user.id, other.id)
    end
  end
end
