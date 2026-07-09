defmodule Elektrine.DeveloperTokensTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Developer

  describe "create_api_token/2" do
    test "requires at least one scope" do
      user = user_fixture()

      assert {:error, changeset} =
               Developer.create_api_token(user.id, %{
                 name: "token-without-scopes",
                 scopes: []
               })

      assert "must include at least one scope" in errors_on(changeset).scopes
    end

    test "accepts dedicated nerve scopes" do
      user = user_fixture()

      assert {:ok, token} =
               Developer.create_api_token(user.id, %{
                 name: "nerve-token",
                 scopes: ["read:nerve", "write:nerve"]
               })

      assert Enum.sort(token.scopes) == ["read:nerve", "write:nerve"]
    end

    test "accepts dedicated moderation scopes" do
      user = user_fixture()

      assert {:ok, token} =
               Developer.create_api_token(user.id, %{
                 name: "moderation-token",
                 scopes: ["read:moderation", "write:moderation"]
               })

      assert Enum.sort(token.scopes) == ["read:moderation", "write:moderation"]
    end

    test "does not create tokens for banned users" do
      user = user_fixture()
      {:ok, banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      assert {:error, changeset} =
               Developer.create_api_token(banned_user.id, %{
                 name: "blocked-token",
                 scopes: ["read:account"]
               })

      assert "is not active" in errors_on(changeset).user_id
    end

    test "enforces the maximum number of active tokens per user" do
      user = user_fixture()

      for idx <- 1..Developer.max_tokens_per_user() do
        assert {:ok, _token} =
                 Developer.create_api_token(user.id, %{
                   name: "token-#{idx}",
                   scopes: ["read:account"]
                 })
      end

      assert {:error, changeset} =
               Developer.create_api_token(user.id, %{
                 name: "token-over-limit",
                 scopes: ["read:account"]
               })

      assert "token limit reached (maximum 20 active tokens)" in errors_on(changeset).name
      assert Developer.count_api_tokens(user.id) == Developer.max_tokens_per_user()
    end
  end

  describe "create_nerve_extension_token/2" do
    test "replaces stale extension tokens before enforcing the token limit" do
      user = user_fixture()

      for idx <- 1..(Developer.max_tokens_per_user() - 1) do
        assert {:ok, _token} =
                 Developer.create_api_token(user.id, %{
                   name: "manual-token-#{idx}",
                   scopes: ["read:account"]
                 })
      end

      assert {:ok, stale_extension_token} =
               Developer.create_api_token(user.id, %{
                 name: "Nerve browser extension",
                 scopes: ["read:nerve", "write:nerve"]
               })

      assert Developer.count_api_tokens(user.id) == Developer.max_tokens_per_user()

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)

      assert {:ok, replacement_token} =
               Developer.create_nerve_extension_token(user.id, expires_at)

      assert String.starts_with?(replacement_token.token, "ekt_")
      assert Developer.count_api_tokens(user.id) == Developer.max_tokens_per_user()

      active_tokens = Developer.list_api_tokens(user.id)

      active_extension_tokens =
        Enum.filter(active_tokens, &(&1.name == "Nerve browser extension"))

      assert Enum.map(active_extension_tokens, & &1.id) == [replacement_token.id]
      refute Enum.any?(active_tokens, &(&1.id == stale_extension_token.id))

      assert replacement_token.scopes == [
               "read:kairo",
               "read:nerve",
               "write:kairo",
               "write:nerve"
             ]
    end
  end

  describe "verify_api_token/2" do
    test "banning a user revokes existing tokens" do
      user = user_fixture()

      assert {:ok, token} =
               Developer.create_api_token(user.id, %{
                 name: "token-before-ban",
                 scopes: ["read:account"]
               })

      assert {:ok, _banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      assert {:error, :invalid_token} = Developer.verify_api_token(token.token)
    end

    test "revokes tokens older than the user's auth boundary" do
      user = user_fixture()

      assert {:ok, token} =
               Developer.create_api_token(user.id, %{
                 name: "old-token",
                 scopes: ["read:account"]
               })

      auth_valid_after =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> DateTime.truncate(:second)

      user
      |> change(%{auth_valid_after: auth_valid_after})
      |> Repo.update!()

      assert {:error, :token_revoked} = Developer.verify_api_token(token.token)
    end
  end
end
