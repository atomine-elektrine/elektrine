defmodule ElektrineWeb.UserSettingsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Vault

  describe "PUT /account/password" do
    test "requires encrypted data rewrap when vault is configured", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert {:ok, _master_key} =
               Vault.setup(user.id, %{
                 "wrapped_dek" => wrapped_payload("old-dek"),
                 "wrapped_dek_recovery" => wrapped_payload("old-recovery")
               })

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_user(user)
        |> put("/account/password", %{
          "user" => %{
            "current_password" => AccountsFixtures.valid_user_password(),
            "password" => "new password!",
            "password_confirmation" => "new password!"
          }
        })

      assert html_response(conn, 200) =~ "Encrypted data must be rewrapped"

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user(user.username, "new password!")

      assert Vault.get(user.id).wrapped_dek["ciphertext"] ==
               wrapped_payload("old-dek")["ciphertext"]
    end

    test "updates password and encrypted data wrapper together", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert {:ok, _master_key} =
               Vault.setup(user.id, %{
                 "wrapped_dek" => wrapped_payload("old-dek"),
                 "wrapped_dek_recovery" => wrapped_payload("old-recovery")
               })

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_user(user)
        |> put("/account/password", %{
          "user" => %{
            "current_password" => AccountsFixtures.valid_user_password(),
            "password" => "new password!",
            "password_confirmation" => "new password!",
            "vault_wrapped_dek" => Jason.encode!(wrapped_payload("new-dek")),
            "vault_wrapped_dek_recovery" => Jason.encode!(wrapped_payload("old-recovery"))
          }
        })

      assert redirected_to(conn) == "/account"
      assert {:ok, _user} = Accounts.authenticate_user(user.username, "new password!")

      master_key = Vault.get(user.id)
      assert master_key.wrapped_dek["ciphertext"] == wrapped_payload("new-dek")["ciphertext"]

      assert master_key.wrapped_dek_recovery["ciphertext"] ==
               wrapped_payload("old-recovery")["ciphertext"]
    end
  end

  describe "POST /announcements/:id/dismiss" do
    test "redirects instead of raising for malformed announcement ids", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_user(user)
        |> Plug.Conn.put_req_header("referer", "https://example.com/account")
        |> post("/announcements/not-an-id/dismiss")

      assert redirected_to(conn) == "/account"
    end
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(
      ElektrineWeb.UserAuth.recent_auth_session_key(),
      System.system_time(:second)
    )
  end

  defp wrapped_payload(value) do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 210_000,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext:" <> value)
    }
  end
end
