defmodule ElektrineWeb.API.TwoFactorAuthenticationControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias ElektrineWeb.Plugs.APIAuth

  describe "mfa settings" do
    test "returns disabled settings for a new user", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> authorize(user)
        |> get("/api/pleroma/accounts/mfa")

      assert %{
               "settings" => %{
                 "enabled" => false,
                 "totp" => %{"enabled" => false, "confirmed" => false},
                 "backup_codes" => 0
               }
             } = json_response(conn, 200)
    end
  end

  describe "totp setup" do
    test "sets up, confirms, regenerates backup codes, and disables totp", %{conn: conn} do
      user = user_fixture()

      setup_conn =
        conn
        |> authorize(user)
        |> get("/api/pleroma/accounts/mfa/setup/totp")

      assert %{
               "method" => "totp",
               "setup_token" => setup_token,
               "provisioning_uri" => provisioning_uri,
               "key" => key,
               "backup_codes" => setup_backup_codes
             } = json_response(setup_conn, 200)

      assert String.starts_with?(provisioning_uri, "otpauth://totp/")
      assert length(setup_backup_codes) == 8

      secret = Base.decode32!(key, padding: false)
      code = NimbleTOTP.verification_code(secret)

      confirm_conn =
        build_conn()
        |> authorize(user)
        |> post("/api/pleroma/accounts/mfa/confirm/totp", %{
          "password" => valid_user_password(),
          "code" => code,
          "setup_token" => setup_token
        })

      assert %{"settings" => %{"enabled" => true, "backup_codes" => 8}} =
               json_response(confirm_conn, 200)

      user = Accounts.get_user!(user.id)
      assert user.two_factor_enabled == true

      backup_codes_conn =
        build_conn()
        |> authorize(user)
        |> get("/api/pleroma/accounts/mfa/backup_codes")

      assert %{"backup_codes" => backup_codes, "settings" => %{"enabled" => true}} =
               json_response(backup_codes_conn, 200)

      assert length(backup_codes) == 8
      refute backup_codes == setup_backup_codes

      disable_conn =
        build_conn()
        |> authorize(user)
        |> delete("/api/pleroma/accounts/mfa/totp", %{"password" => valid_user_password()})

      assert %{"settings" => %{"enabled" => false, "backup_codes" => 0}} =
               json_response(disable_conn, 200)

      user = Accounts.get_user!(user.id)
      assert user.two_factor_enabled == false
    end

    test "rejects invalid setup methods", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> authorize(user)
        |> get("/api/pleroma/accounts/mfa/setup/sms")

      assert %{"error" => "undefined mfa method"} = json_response(conn, 400)
    end

    test "rejects invalid password during confirm", %{conn: conn} do
      user = user_fixture()

      setup_conn =
        conn
        |> authorize(user)
        |> get("/api/pleroma/accounts/mfa/setup/totp")

      %{"setup_token" => setup_token, "key" => key} = json_response(setup_conn, 200)
      code = key |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()

      confirm_conn =
        build_conn()
        |> authorize(user)
        |> post("/api/pleroma/accounts/mfa/confirm/totp", %{
          "password" => "wrong password",
          "code" => code,
          "setup_token" => setup_token
        })

      assert %{"error" => "Password is incorrect"} = json_response(confirm_conn, 401)
    end
  end

  defp authorize(conn, user) do
    {:ok, token} = APIAuth.generate_token(user.id)

    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
