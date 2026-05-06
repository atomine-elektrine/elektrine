defmodule Elektrine.Accounts.AppPasswordTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.AppPassword
  alias Elektrine.Repo

  describe "app password authentication" do
    test "generates high-entropy displayed tokens and stores versioned HMAC hashes" do
      user = user_fixture()

      assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Mail client"})

      assert app_password.token =~ ~r/^[a-z2-7]{4}(-[a-z2-7]{4}){7}$/
      assert String.starts_with?(app_password.token_hash, "v2$hmac-sha256$")

      clean_token = String.replace(app_password.token, "-", "")
      refute app_password.token_hash == legacy_sha256_hash(clean_token)
      assert AppPassword.verify_token(clean_token, app_password.token_hash)
    end

    test "authenticates generated app passwords with display separators and uppercase typing" do
      user = user_fixture()

      assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Thunderbird"})

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, app_password.token)

      assert authenticated_user.id == user.id

      typed_token = String.upcase(app_password.token)

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, typed_token)

      assert authenticated_user.id == user.id
    end

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

    test "still accepts existing legacy SHA-256 app password hashes" do
      user = user_fixture()
      token = "legacytoken#{System.unique_integer([:positive])}"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Old mail client",
          user_id: user.id,
          token_hash: legacy_sha256_hash(token)
        })
        |> Repo.insert()

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert authenticated_user.id == user.id
    end

    test "still accepts existing legacy SHA-256 app password hashes with literal hyphens" do
      user = user_fixture()
      token = "legacy-token-#{System.unique_integer([:positive])}"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Old mail client with url-safe token",
          user_id: user.id,
          token_hash: legacy_sha256_hash(token)
        })
        |> Repo.insert()

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert authenticated_user.id == user.id
    end
  end

  defp legacy_sha256_hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end
end
