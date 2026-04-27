defmodule Elektrine.Accounts.AppPasswordTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts

  describe "app password authentication" do
    test "rejects a token after its app password is deleted" do
      user = user_fixture()
      {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Mail client"})

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, app_password.token)

      assert authenticated_user.id == user.id

      assert {:ok, _deleted_app_password} =
               Accounts.delete_app_password(app_password.id, user.id)

      assert {:error, {:invalid_token, invalid_token_user}} =
               Accounts.authenticate_with_app_password(user.username, app_password.token)

      assert invalid_token_user.id == user.id
    end
  end
end
