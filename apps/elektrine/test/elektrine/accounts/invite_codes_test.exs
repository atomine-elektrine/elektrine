defmodule Elektrine.Accounts.InviteCodesTest do
  use Elektrine.DataCase

  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.Accounts.InviteCode
  alias Elektrine.Accounts.InviteCodeUse
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo

  describe "invite code normalization" do
    test "normalizes invite codes on create and lookup" do
      admin = AccountsFixtures.user_fixture()

      assert {:ok, invite_code} =
               Accounts.create_invite_code(%{
                 code: "  mixed123  ",
                 max_uses: 2,
                 created_by_id: admin.id
               })

      assert invite_code.code == "MIXED123"
      assert Accounts.get_invite_code_by_code("mixed123").id == invite_code.id
      assert Accounts.get_invite_code_by_code("  MIXED123 ").id == invite_code.id
    end

    test "rejects duplicate codes case-insensitively" do
      admin = AccountsFixtures.user_fixture()

      assert {:ok, _invite_code} =
               Accounts.create_invite_code(%{
                 code: "ALPHA123",
                 created_by_id: admin.id
               })

      assert {:error, changeset} =
               Accounts.create_invite_code(%{
                 code: " alpha123 ",
                 created_by_id: admin.id
               })

      assert "has already been taken" in errors_on(changeset).code
    end
  end

  describe "invite code updates" do
    test "does not allow lowering max uses below current usage" do
      admin = AccountsFixtures.user_fixture()
      first_user = AccountsFixtures.user_fixture()

      assert {:ok, invite_code} =
               Accounts.create_invite_code(%{
                 code: "LIMIT123",
                 max_uses: 2,
                 created_by_id: admin.id
               })

      assert {:ok, _claimed_code} = Accounts.use_invite_code(invite_code.code, first_user.id)

      invite_code = Accounts.get_invite_code!(invite_code.id)

      assert {:error, changeset} = Accounts.update_invite_code(invite_code, %{max_uses: 0})
      assert "cannot be less than current uses (1)" in errors_on(changeset).max_uses
    end

    test "ignores code changes on update" do
      admin = AccountsFixtures.user_fixture()

      assert {:ok, invite_code} =
               Accounts.create_invite_code(%{
                 code: "LOCKED12",
                 note: "before",
                 created_by_id: admin.id
               })

      assert {:ok, updated_invite_code} =
               Accounts.update_invite_code(invite_code, %{
                 code: "CHANGED12",
                 note: "after"
               })

      assert updated_invite_code.code == "LOCKED12"
      assert updated_invite_code.note == "after"
    end
  end

  describe "register_user_with_invite/1" do
    test "creates the user and records invite usage atomically" do
      admin = AccountsFixtures.user_fixture()

      assert {:ok, invite_code} =
               Accounts.create_invite_code(%{
                 code: "JOIN123",
                 created_by_id: admin.id
               })

      username = "invited#{System.unique_integer([:positive])}"

      assert {:ok, user} =
               Accounts.register_user_with_invite(%{
                 username: username,
                 password: "validpassword123",
                 password_confirmation: "validpassword123",
                 invite_code: String.downcase(invite_code.code)
               })

      invite_code = Accounts.get_invite_code!(invite_code.id)

      assert invite_code.uses_count == 1

      assert Repo.get_by(InviteCodeUse, invite_code_id: invite_code.id, user_id: user.id)
      assert Accounts.get_user_by_username(username).id == user.id
    end

    test "rolls back the user when the invite code is invalid" do
      username = "rolledback#{System.unique_integer([:positive])}"

      assert {:error, changeset} =
               Accounts.register_user_with_invite(%{
                 username: username,
                 password: "validpassword123",
                 password_confirmation: "validpassword123",
                 invite_code: "missing12"
               })

      assert "Invalid invite code" in errors_on(changeset).invite_code
      refute Accounts.get_user_by_username(username)
    end

    test "rolls back the user when the invite code is exhausted" do
      admin = AccountsFixtures.user_fixture()
      first_user = AccountsFixtures.user_fixture()

      assert {:ok, invite_code} =
               Accounts.create_invite_code(%{
                 code: "FULL123",
                 max_uses: 1,
                 created_by_id: admin.id
               })

      assert {:ok, _claimed_code} = Accounts.use_invite_code(invite_code.code, first_user.id)

      username = "exhausted#{System.unique_integer([:positive])}"

      assert {:error, changeset} =
               Accounts.register_user_with_invite(%{
                 username: username,
                 password: "validpassword123",
                 password_confirmation: "validpassword123",
                 invite_code: invite_code.code
               })

      assert "This invite code has reached its usage limit" in errors_on(changeset).invite_code
      refute Accounts.get_user_by_username(username)
    end
  end

  describe "get_invite_code_stats/0" do
    test "counts only usable codes as active" do
      admin = AccountsFixtures.user_fixture()
      exhausted_user = AccountsFixtures.user_fixture()

      assert {:ok, _active_code} =
               Accounts.create_invite_code(%{
                 code: "ACTIVE12",
                 created_by_id: admin.id
               })

      assert {:ok, _expired_code} =
               Accounts.create_invite_code(%{
                 code: "EXPIRE12",
                 expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
                 created_by_id: admin.id
               })

      assert {:ok, exhausted_code} =
               Accounts.create_invite_code(%{
                 code: "SPENT123",
                 max_uses: 1,
                 created_by_id: admin.id
               })

      assert {:ok, _inactive_code} =
               Accounts.create_invite_code(%{
                 code: "OFFLINE1",
                 is_active: false,
                 created_by_id: admin.id
               })

      assert {:ok, _claimed_code} =
               Accounts.use_invite_code(exhausted_code.code, exhausted_user.id)

      assert %{total: 4, active: 1, expired: 1, exhausted: 1} = Accounts.get_invite_code_stats()
    end
  end

  describe "self-service invite codes" do
    setup do
      previous_value = Elektrine.System.invite_codes_enabled?()
      previous_min_trust_level = Elektrine.System.self_service_invite_min_trust_level()

      on_exit(fn ->
        Elektrine.System.set_invite_codes_enabled(previous_value)
        Elektrine.System.set_self_service_invite_min_trust_level(previous_min_trust_level)
      end)

      {:ok, _config} = Elektrine.System.set_invite_codes_enabled(true)
      {:ok, _config} = Elektrine.System.set_self_service_invite_min_trust_level(1)
      :ok
    end

    test "trusted users can create constrained invite codes" do
      user = AccountsFixtures.user_fixture()
      {:ok, trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})

      assert {:ok, invite_code} =
               Accounts.create_self_service_invite_code(trusted_user, %{note: "Friend access"})

      assert invite_code.created_by_id == trusted_user.id
      assert invite_code.max_uses == 1
      assert invite_code.note == "Friend access"
      assert DateTime.diff(invite_code.expires_at, DateTime.utc_now(), :second) > 13 * 86_400

      assert [listed_invite_code] = Accounts.list_user_invite_codes(trusted_user.id)
      assert listed_invite_code.id == invite_code.id
    end

    test "requires trust level for self-service invites" do
      user = AccountsFixtures.user_fixture()

      assert {:error, :insufficient_trust_level} =
               Accounts.create_self_service_invite_code(user, %{})
    end

    test "enforces the active self-service invite limit" do
      user = AccountsFixtures.user_fixture()
      {:ok, trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})

      for _ <- 1..5 do
        assert {:ok, _invite_code} = Accounts.create_self_service_invite_code(trusted_user, %{})
      end

      assert {:error, :invite_code_limit_reached} =
               Accounts.create_self_service_invite_code(trusted_user, %{})
    end

    test "enforces a monthly self-service invite generation limit even after deactivation" do
      user = AccountsFixtures.user_fixture()
      {:ok, trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})

      invite_codes =
        for _ <- 1..5 do
          assert {:ok, invite_code} =
                   Accounts.create_self_service_invite_code(trusted_user, %{})

          invite_code
        end

      for invite_code <- invite_codes do
        assert {:ok, _invite_code} =
                 Accounts.deactivate_self_service_invite_code(trusted_user, invite_code.id)
      end

      assert {:error, :monthly_invite_code_limit_reached} =
               Accounts.create_self_service_invite_code(trusted_user, %{})
    end

    test "blocks registrations after a creator reaches the monthly invite redemption limit" do
      user = AccountsFixtures.user_fixture()
      {:ok, trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})

      invite_codes =
        for _ <- 1..5 do
          assert {:ok, invite_code} =
                   Accounts.create_self_service_invite_code(trusted_user, %{})

          backdate_invite_code_to_previous_month(invite_code)
        end

      for invite_code <- invite_codes do
        assert {:ok, _user} =
                 Accounts.register_user_with_invite(%{
                   username: "monthlyused#{System.unique_integer([:positive])}",
                   password: "validpassword123",
                   password_confirmation: "validpassword123",
                   invite_code: invite_code.code
                 })
      end

      assert {:ok, current_month_invite} =
               Accounts.create_self_service_invite_code(trusted_user, %{})

      assert {:error, changeset} =
               Accounts.register_user_with_invite(%{
                 username: "monthlyblocked#{System.unique_integer([:positive])}",
                 password: "validpassword123",
                 password_confirmation: "validpassword123",
                 invite_code: current_month_invite.code
               })

      assert "This invite code is temporarily unavailable right now" in errors_on(changeset).invite_code
    end

    test "uses the configured minimum trust level" do
      user = AccountsFixtures.user_fixture()
      {:ok, semi_trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})
      {:ok, _config} = Elektrine.System.set_self_service_invite_min_trust_level(2)

      assert {:error, :insufficient_trust_level} =
               Accounts.create_self_service_invite_code(semi_trusted_user, %{})
    end
  end

  defp backdate_invite_code_to_previous_month(%InviteCode{} = invite_code) do
    previous_month_start =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> Date.add(-1)
      |> Date.beginning_of_month()

    previous_month_timestamp = NaiveDateTime.new!(previous_month_start, ~T[00:00:00])

    from(i in InviteCode, where: i.id == ^invite_code.id)
    |> Repo.update_all(set: [inserted_at: previous_month_timestamp])

    %{invite_code | inserted_at: previous_month_timestamp}
  end
end
