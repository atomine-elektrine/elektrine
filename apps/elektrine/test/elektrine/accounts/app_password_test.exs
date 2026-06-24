defmodule Elektrine.Accounts.AppPasswordTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.AppPassword
  alias Elektrine.Email
  alias Elektrine.Repo

  describe "app password authentication" do
    test "generates high-entropy displayed tokens and stores Argon2id hashes" do
      user = user_fixture()

      assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Mail client"})

      assert app_password.token =~ ~r/^[a-z2-7]{4}(-[a-z2-7]{4}){7}$/
      assert String.starts_with?(app_password.token_hash, "v3$argon2id$$argon2id$")

      clean_token = String.replace(app_password.token, "-", "")
      refute app_password.token_hash == legacy_sha256_hash(clean_token)
      assert AppPassword.verify_token(clean_token, app_password.token_hash)
    end

    test "creates and authenticates app passwords without global runtime secrets" do
      user = user_fixture()

      with_app_password_secrets(nil, fn ->
        assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Secretless"})
        assert String.starts_with?(app_password.token_hash, "v3$argon2id$")

        assert {:ok, authenticated_user} =
                 Accounts.authenticate_with_app_password(user.username, app_password.token)

        assert authenticated_user.id == user.id
      end)
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

    test "authenticates generated app passwords with mailbox email identifier" do
      user = user_fixture()
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Mail app"})

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(mailbox.email, app_password.token)

      assert authenticated_user.id == user.id
    end

    test "accepts v3 hashes created from displayed tokens with separators" do
      user = user_fixture()
      token = "abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Displayed token hash",
          user_id: user.id,
          token_hash: AppPassword.hash_token(token)
        })
        |> Repo.insert()

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert authenticated_user.id == user.id
    end

    test "accepts v3 Argon2id hashes created from legacy displayed tokens" do
      user = user_fixture()
      token = "abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Legacy displayed Argon2id token",
          user_id: user.id,
          token_hash: "v3$argon2id$" <> Argon2.hash_pwd_salt(token)
        })
        |> Repo.insert()

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, String.upcase(token))

      assert authenticated_user.id == user.id
    end

    test "accepts raw Argon2id app password hashes without v3 prefix" do
      user = user_fixture()
      token = "abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Raw Argon2id token",
          user_id: user.id,
          token_hash: Argon2.hash_pwd_salt(token)
        })
        |> Repo.insert()

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert authenticated_user.id == user.id
    end

    test "still accepts existing v2 HMAC app password hashes when the pepper exists" do
      user = user_fixture()
      token = "abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567"
      pepper = "stable-app-password-pepper"

      with_app_password_secrets(pepper, fn ->
        {:ok, _app_password} =
          %AppPassword{}
          |> AppPassword.changeset(%{
            name: "Old HMAC mail client",
            user_id: user.id,
            token_hash: hmac_sha256_hash(normalized_current_token(token), pepper)
          })
          |> Repo.insert()

        assert {:ok, authenticated_user} =
                 Accounts.authenticate_with_app_password(user.username, token)

        assert authenticated_user.id == user.id
      end)
    end

    test "ignores copy-paste separators around current generated tokens" do
      user = user_fixture()
      assert {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Mail app"})

      pasted_token =
        app_password.token
        |> String.replace("-", "\u2011")
        |> then(&(" " <> &1 <> "\n"))

      assert {:ok, authenticated_user} =
               Accounts.authenticate_with_app_password(user.username, pasted_token)

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

    test "rejects existing legacy SHA-256 app password hashes" do
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

      assert {:error, {:invalid_token, invalid_token_user}} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert invalid_token_user.id == user.id
    end

    test "rejects original 4-group SHA-256 app password hashes" do
      user = user_fixture()
      token = "abcd-efgh-ijkl-mnop"
      clean_token = "abcdefghijklmnop"

      {:ok, _app_password} =
        %AppPassword{}
        |> AppPassword.changeset(%{
          name: "Original mail client token",
          user_id: user.id,
          token_hash: legacy_sha256_hash(clean_token)
        })
        |> Repo.insert()

      for typed_token <- [token, String.upcase(token), clean_token] do
        assert {:error, {:invalid_token, invalid_token_user}} =
                 Accounts.authenticate_with_app_password(user.username, typed_token)

        assert invalid_token_user.id == user.id
      end
    end

    test "rejects existing legacy SHA-256 app password hashes with literal hyphens" do
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

      assert {:error, {:invalid_token, invalid_token_user}} =
               Accounts.authenticate_with_app_password(user.username, token)

      assert invalid_token_user.id == user.id
    end

    test "reports app password hash versions for diagnostics" do
      assert AppPassword.hash_version("v3$argon2id$" <> Argon2.hash_pwd_salt("token")) ==
               :v3_argon2id

      assert AppPassword.hash_version(Argon2.hash_pwd_salt("token")) == :argon2id
      assert AppPassword.hash_version("v2$hmac-sha256$abc") == :v2_hmac
      assert AppPassword.hash_version(legacy_sha256_hash("token")) == :unknown
      assert AppPassword.hash_version(nil) == :unknown
    end
  end

  defp legacy_sha256_hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp hmac_sha256_hash(token, pepper) do
    "v2$hmac-sha256$" <>
      (:crypto.mac(:hmac, :sha256, pepper, token) |> Base.url_encode64(padding: false))
  end

  defp normalized_current_token(token) do
    token
    |> String.replace(~r/[^a-z2-7]/i, "")
    |> String.downcase()
  end

  defp with_app_password_secrets(pepper, fun) do
    old_pepper = Application.get_env(:elektrine, :app_password_pepper)
    old_encryption_secret = Application.get_env(:elektrine, :encryption_master_secret)
    old_endpoint_config = Application.get_env(:elektrine, ElektrineWeb.Endpoint, [])

    try do
      if pepper do
        Application.put_env(:elektrine, :app_password_pepper, pepper)
      else
        Application.delete_env(:elektrine, :app_password_pepper)
      end

      Application.delete_env(:elektrine, :encryption_master_secret)

      Application.put_env(
        :elektrine,
        ElektrineWeb.Endpoint,
        Keyword.delete(old_endpoint_config, :secret_key_base)
      )

      fun.()
    after
      restore_env(:app_password_pepper, old_pepper)
      restore_env(:encryption_master_secret, old_encryption_secret)
      Application.put_env(:elektrine, ElektrineWeb.Endpoint, old_endpoint_config)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
