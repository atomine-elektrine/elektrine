defmodule ElektrineWeb.API.PasswordResetControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Changeset
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  setup do
    previous_mailer_config = Application.get_env(:elektrine, Elektrine.Mailer, [])

    Application.put_env(
      :elektrine,
      Elektrine.Mailer,
      Keyword.merge(previous_mailer_config, adapter: Swoosh.Adapters.Test)
    )

    on_exit(fn ->
      Application.put_env(:elektrine, Elektrine.Mailer, previous_mailer_config)
    end)

    :ok
  end

  describe "request/2" do
    test "initiates a reset by nickname without exposing account state", %{conn: conn} do
      user = user_fixture(%{username: "apiresetuser"})
      set_recovery_email_verified(user, "api-reset@example.com")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/password", %{"nickname" => user.username})

      assert response(conn, 204) == ""
      assert extract_password_reset_token()
      assert Accounts.get_user!(user.id).password_reset_token
    end

    test "accepts missing accounts with the same no-content response", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/accounts/password_reset", %{"email" => "missing@example.com"})

      assert response(conn, 204) == ""
      refute_received {:email, _email}
    end

    test "rejects requests without an identifier", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/accounts/password_reset", %{})

      assert %{"error" => "email or nickname is required"} = json_response(conn, 400)
    end
  end

  describe "confirm/2" do
    test "resets a password with a valid token", %{conn: conn} do
      user = user_fixture(%{username: "apiconfirmuser"})
      set_recovery_email_verified(user, "api-confirm@example.com")
      {:ok, :emails_sent} = Accounts.initiate_password_reset(user.username)
      token = extract_password_reset_token()

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/accounts/password_reset/confirm", %{
          "token" => token,
          "password" => "new_api_password123",
          "password_confirmation" => "new_api_password123"
        })

      assert %{"status" => "ok"} = json_response(conn, 200)

      reloaded = Accounts.get_user!(user.id)
      assert Argon2.verify_pass("new_api_password123", reloaded.password_hash)
      assert is_nil(reloaded.password_reset_token)
      assert is_nil(reloaded.password_reset_token_expires_at)
    end

    test "accepts legacy confirmation payload shape", %{conn: conn} do
      user = user_fixture(%{username: "apilegacyreset"})
      set_recovery_email_verified(user, "api-legacy@example.com")
      {:ok, :emails_sent} = Accounts.initiate_password_reset(user.username)
      token = extract_password_reset_token()

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/pleroma/password_reset", %{
          "data" => %{
            "token" => token,
            "password" => "legacy_api_password123",
            "password_confirmation" => "legacy_api_password123"
          }
        })

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "returns validation errors for weak passwords", %{conn: conn} do
      user = user_fixture(%{username: "apiweakreset"})
      set_recovery_email_verified(user, "api-weak@example.com")
      {:ok, :emails_sent} = Accounts.initiate_password_reset(user.username)
      token = extract_password_reset_token()

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/accounts/password_reset/confirm", %{
          "token" => token,
          "password" => "short",
          "password_confirmation" => "short"
        })

      assert %{
               "error" => "invalid_password",
               "details" => %{"password" => [_ | _]}
             } = json_response(conn, 422)
    end

    test "rejects invalid tokens", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/accounts/password_reset/confirm", %{
          "token" => "invalid-token",
          "password" => "new_api_password123",
          "password_confirmation" => "new_api_password123"
        })

      assert %{"error" => "invalid_token"} = json_response(conn, 422)
    end
  end

  defp set_recovery_email_verified(%User{} = user, email) do
    user
    |> change(%{recovery_email: email, recovery_email_verified: true})
    |> Repo.update!()
  end

  defp extract_password_reset_token do
    assert_received {:email, email}
    [_, token] = Regex.run(~r{/password/reset/([A-Za-z0-9_-]+)}, email.text_body)
    token
  end
end
