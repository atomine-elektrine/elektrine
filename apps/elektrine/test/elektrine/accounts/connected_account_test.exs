defmodule Elektrine.Accounts.ConnectedAccountTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Accounts.ConnectedAccount
  alias Elektrine.AccountsFixtures

  describe "connected accounts" do
    test "upserts a provider account for a user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, account} =
               Accounts.upsert_connected_account(user, %{
                 provider: "GitHub",
                 provider_account_id: "12345",
                 username: "octo",
                 profile_url: "https://github.com/octo",
                 scopes: ["read:user"]
               })

      assert %ConnectedAccount{} = account
      assert account.provider == "github"
      assert account.provider_account_id == "12345"
      assert account.username == "octo"
      assert account.last_verified_at

      assert [^account] = Accounts.list_connected_accounts(user.id)

      assert {:ok, updated} =
               Accounts.upsert_connected_account(user, %{
                 provider: "github",
                 provider_account_id: "12345",
                 username: "octocat"
               })

      assert updated.id == account.id
      assert updated.username == "octocat"
    end

    test "does not allow one provider account to attach to two users" do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()

      assert {:ok, _account} =
               Accounts.upsert_connected_account(user, %{
                 provider: "github",
                 provider_account_id: "12345"
               })

      assert {:error, :provider_account_already_connected} =
               Accounts.upsert_connected_account(other_user, %{
                 provider: "github",
                 provider_account_id: "12345"
               })
    end
  end
end
