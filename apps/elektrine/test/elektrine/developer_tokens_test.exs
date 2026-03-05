defmodule Elektrine.DeveloperTokensTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer

  describe "create_api_token/2" do
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
end
