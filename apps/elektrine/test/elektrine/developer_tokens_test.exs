defmodule Elektrine.DeveloperTokensTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

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

  describe "verify_api_token/2" do
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
