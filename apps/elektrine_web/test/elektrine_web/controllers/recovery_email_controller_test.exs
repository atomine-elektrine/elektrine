defmodule ElektrineWeb.RecoveryEmailControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Repo

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "recoverytest#{System.unique_integer([:positive])}",
        password: "password123456",
        password_confirmation: "password123456"
      })

    %{user: user}
  end

  describe "GET /verify-recovery-email" do
    test "successfully verifies valid token", %{conn: conn, user: user} do
      # Set up user with valid token
      token = "valid_test_token_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        email_rate_limit_violations: 3,
        email_restriction_reason: "Test restriction",
        email_restricted_at: now,
        recovery_email: "recovery@example.com",
        recovery_email_verified: false,
        recovery_email_verification_token: token,
        recovery_email_verification_sent_at: now
      })
      |> Repo.update!()

      conn = get(conn, ~p"/verify-recovery-email", %{"token" => token})

      assert html_response(conn, 200) =~ "Email Sending Restored"
      assert html_response(conn, 200) =~ "You can now send emails again"

      # Verify user is updated
      updated_user = Accounts.get_user!(user.id)
      assert updated_user.email_sending_restricted == false
      assert updated_user.recovery_email_verified == true
      assert updated_user.recovery_email_verification_token == nil
    end

    test "shows error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email", %{"token" => "invalid_token_123"})

      assert html_response(conn, 200) =~ "Verification Failed"
      assert html_response(conn, 200) =~ "invalid or has already been used"
    end

    test "shows error for expired token", %{conn: conn, user: user} do
      # Set up user with expired token (sent 25 hours ago)
      expired_time =
        DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:second)

      token = "expired_test_token_#{System.unique_integer([:positive])}"

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verification_token: token,
        recovery_email_verification_sent_at: expired_time
      })
      |> Repo.update!()

      conn = get(conn, ~p"/verify-recovery-email", %{"token" => token})

      assert html_response(conn, 200) =~ "Verification Failed"
      assert html_response(conn, 200) =~ "expired"
      assert html_response(conn, 200) =~ "valid for 24 hours"
    end

    test "shows error when token is missing", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email")

      assert html_response(conn, 200) =~ "Verification Failed"
      assert html_response(conn, 200) =~ "invalid"
    end

    test "shows error when token is empty", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email", %{"token" => ""})

      assert html_response(conn, 200) =~ "Verification Failed"
    end

    test "contains link to account settings", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email", %{"token" => "any_token"})

      assert html_response(conn, 200) =~ "Account Settings"
      assert html_response(conn, 200) =~ "/account"
    end

    test "contains link to login page", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email", %{"token" => "any_token"})

      assert html_response(conn, 200) =~ "Back to Login"
      assert html_response(conn, 200) =~ "/login"
    end
  end

  describe "verification with flash messages" do
    test "sets success flash on successful verification", %{conn: conn, user: user} do
      token = "flash_test_token_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verification_token: token,
        recovery_email_verification_sent_at: now
      })
      |> Repo.update!()

      conn = get(conn, ~p"/verify-recovery-email", %{"token" => token})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "recovery email has been verified"
    end

    test "sets error flash on invalid token", %{conn: conn} do
      conn = get(conn, ~p"/verify-recovery-email", %{"token" => "bad_token"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Invalid or expired"
    end

    test "sets error flash on expired token", %{conn: conn, user: user} do
      expired_time =
        DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:second)

      token = "expired_flash_token_#{System.unique_integer([:positive])}"

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verification_token: token,
        recovery_email_verification_sent_at: expired_time
      })
      |> Repo.update!()

      conn = get(conn, ~p"/verify-recovery-email", %{"token" => token})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "expired"
    end
  end
end
