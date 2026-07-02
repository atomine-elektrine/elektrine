defmodule ElektrineWeb.API.AccountRegistrationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.System, as: SystemSettings
  alias ElektrineWeb.Plugs.APIAuth

  import Elektrine.AccountsFixtures

  setup do
    previous_invite_setting = SystemSettings.invite_codes_enabled?()
    previous_pow_config = Application.get_env(:elektrine, :atomine_pow, [])

    Application.put_env(:elektrine, :atomine_pow, skip_verification: true)

    on_exit(fn ->
      SystemSettings.set_invite_codes_enabled(previous_invite_setting)
      Application.put_env(:elektrine, :atomine_pow, previous_pow_config)
    end)

    :ok
  end

  describe "POST /api/v1/accounts" do
    test "creates an account when registration is open and returns a bearer token", %{conn: conn} do
      {:ok, _config} = SystemSettings.set_invite_codes_enabled(false)
      username = "apiopen#{System.unique_integer([:positive])}"

      conn =
        post(conn, "/api/v1/accounts", %{
          "username" => username,
          "password" => "validpassword123",
          "agreement" => true,
          "scope" => "read, write, follow"
        })

      assert %{
               "access_token" => token,
               "token_type" => "Bearer",
               "scope" => "read write follow",
               "id" => id,
               "username" => ^username
             } = json_response(conn, 200)

      assert {:ok, user} = APIAuth.verify_user_token(token)
      assert user.id == String.to_integer(id)
      assert user.username == username
      assert Accounts.get_user_by_username(username)
    end

    test "uses invite-only registration policy", %{conn: conn} do
      {:ok, _config} = SystemSettings.set_invite_codes_enabled(true)
      username = "apiinvitefail#{System.unique_integer([:positive])}"

      conn =
        post(conn, "/api/v1/accounts", %{
          "username" => username,
          "password" => "validpassword123",
          "agreement" => true
        })

      assert %{
               "error" => "invalid_registration",
               "details" => %{"registration_access_token" => [_ | _]}
             } = json_response(conn, 422)

      refute Accounts.get_user_by_username(username)
    end

    test "consumes a valid invite code", %{conn: conn} do
      {:ok, _config} = SystemSettings.set_invite_codes_enabled(true)
      inviter = user_fixture()

      {:ok, invite_code} =
        Accounts.create_invite_code(%{
          code: "APIJOIN1",
          created_by_id: inviter.id
        })

      username = "apiinviteok#{System.unique_integer([:positive])}"

      conn =
        post(conn, "/api/v1/accounts", %{
          "username" => username,
          "password" => "validpassword123",
          "agreement" => true,
          "invite_code" => String.downcase(invite_code.code)
        })

      assert %{"access_token" => token, "username" => ^username} = json_response(conn, 200)
      assert {:ok, user} = APIAuth.verify_user_token(token)
      assert user.username == username

      invite_code = Accounts.get_invite_code!(invite_code.id)
      assert invite_code.uses_count == 1
    end

    test "accepts captcha_solution for onion API registration", %{conn: conn} do
      {:ok, _config} = SystemSettings.set_invite_codes_enabled(false)
      {_, answer, token} = Elektrine.Captcha.generate()
      username = "apicaptcha#{System.unique_integer([:positive])}"

      conn =
        %{conn | host: "testinstance.onion"}
        |> post("/api/v1/accounts", %{
          "username" => username,
          "password" => "validpassword123",
          "agreement" => true,
          "captcha_token" => token,
          "captcha_solution" => answer
        })

      assert %{"access_token" => token, "username" => ^username} = json_response(conn, 200)
      assert {:ok, user} = APIAuth.verify_user_token(token)
      assert user.registered_via_onion
    end

    test "returns registration changeset errors", %{conn: conn} do
      {:ok, _config} = SystemSettings.set_invite_codes_enabled(false)

      conn =
        post(conn, "/api/v1/accounts", %{
          "username" => "a",
          "password" => "validpassword123",
          "agreement" => false
        })

      assert %{
               "error" => "invalid_registration",
               "details" => %{
                 "agree_to_terms" => [_ | _],
                 "username" => [_ | _]
               }
             } = json_response(conn, 422)
    end
  end
end
