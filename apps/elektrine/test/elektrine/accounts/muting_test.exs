defmodule Elektrine.Accounts.MutingTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts

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
  end
end
