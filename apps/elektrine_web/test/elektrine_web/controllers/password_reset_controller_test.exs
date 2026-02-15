defmodule ElektrineWeb.PasswordResetControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Repo
  import Ecto.Changeset
  import Elektrine.DataCase, only: [errors_on: 1]

  # Helper to set recovery email as verified (bypasses normal validation)
  defp set_recovery_email_verified(user, email) do
    user
    |> change(%{recovery_email: email, recovery_email_verified: true})
    |> Repo.update!()
  end

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "testuser",
        password: "password123456",
        password_confirmation: "password123456"
      })

    %{user: user}
  end

  describe "POST /password/reset" do
    test "initiates password reset for valid username", %{conn: conn, user: user} do
      # Add verified recovery email to user
      _user = set_recovery_email_verified(user, "recovery@example.com")

      conn =
        post(conn, ~p"/password/reset", %{
          "password_reset" => %{"username_or_email" => user.username},
          "cf-turnstile-response" => "test-token"
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password reset instructions"

      # Verify reset token was created
      updated_user = Accounts.get_user!(user.id)
      assert updated_user.password_reset_token
      assert updated_user.password_reset_token_expires_at
    end

    test "initiates password reset for valid recovery email", %{conn: conn, user: user} do
      # Add verified recovery email to user
      recovery_email = "recovery@example.com"
      _user = set_recovery_email_verified(user, recovery_email)

      conn =
        post(conn, ~p"/password/reset", %{
          "password_reset" => %{"username_or_email" => recovery_email},
          "cf-turnstile-response" => "test-token"
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password reset instructions"
    end

    test "shows success message for non-existent user (security)", %{conn: conn} do
      conn =
        post(conn, ~p"/password/reset", %{
          "password_reset" => %{"username_or_email" => "nonexistent"},
          "cf-turnstile-response" => "test-token"
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password reset instructions"
    end

    test "handles flattened parameters (JSON format)", %{conn: conn, user: user} do
      # Add verified recovery email to user
      _user = set_recovery_email_verified(user, "recovery@example.com")

      conn =
        post(conn, ~p"/password/reset", %{
          "password_reset[username_or_email]" => user.username,
          "cf-turnstile-response" => "test-token"
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password reset instructions"
    end
  end

  describe "Password reset token validation" do
    test "validates password reset token", %{user: user} do
      # Add verified recovery email and initiate password reset
      _user = set_recovery_email_verified(user, "recovery@example.com")
      {:ok, _result} = Accounts.initiate_password_reset(user.username)

      # Get the token from the updated user
      updated_user = Accounts.get_user!(user.id)
      token = updated_user.password_reset_token

      # Valid token should return user
      assert {:ok, _user} = Accounts.validate_password_reset_token(token)
    end

    test "rejects invalid token", %{user: _user} do
      assert {:error, :invalid_token} = Accounts.validate_password_reset_token("invalid_token")
    end

    test "rejects expired token", %{user: user} do
      # Create an expired token
      expired_time = DateTime.add(DateTime.utc_now(), -2, :hour)

      {:ok, _user} =
        Accounts.update_user(user, %{
          password_reset_token: "expired_token_123",
          password_reset_token_expires_at: expired_time,
          recovery_email: "recovery@example.com"
        })

      assert {:error, :invalid_token} =
               Accounts.validate_password_reset_token("expired_token_123")
    end
  end

  describe "Password reset with token" do
    test "successfully resets password", %{user: user} do
      # Add verified recovery email and initiate password reset
      _user = set_recovery_email_verified(user, "recovery@example.com")
      {:ok, _result} = Accounts.initiate_password_reset(user.username)

      # Get the token from the updated user
      updated_user = Accounts.get_user!(user.id)
      token = updated_user.password_reset_token

      new_password = "new_valid_password123"

      # Reset password
      assert {:ok, _user} =
               Accounts.reset_password_with_token(token, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      # Verify the password was changed by trying to get user with new password
      updated_user = Accounts.get_user!(user.id)
      assert Argon2.verify_pass(new_password, updated_user.password_hash)

      # Verify the token was cleared
      final_user = Accounts.get_user!(user.id)
      assert is_nil(final_user.password_reset_token)
      assert is_nil(final_user.password_reset_token_expires_at)
    end

    test "rejects mismatched passwords", %{user: user} do
      # Add verified recovery email and initiate password reset
      _user = set_recovery_email_verified(user, "recovery@example.com")
      {:ok, _result} = Accounts.initiate_password_reset(user.username)

      # Get the token from the updated user
      updated_user = Accounts.get_user!(user.id)
      token = updated_user.password_reset_token

      # Try to reset with mismatched passwords
      assert {:error, changeset} =
               Accounts.reset_password_with_token(token, %{
                 password: "password123",
                 password_confirmation: "different123"
               })

      assert "does not match password" in errors_on(changeset).password_confirmation
    end

    test "rejects weak passwords", %{user: user} do
      # Add verified recovery email and initiate password reset
      _user = set_recovery_email_verified(user, "recovery@example.com")
      {:ok, _result} = Accounts.initiate_password_reset(user.username)

      # Get the token from the updated user
      updated_user = Accounts.get_user!(user.id)
      token = updated_user.password_reset_token

      # Try to reset with weak password
      assert {:error, changeset} =
               Accounts.reset_password_with_token(token, %{
                 password: "weak",
                 password_confirmation: "weak"
               })

      assert "should be at least 8 character(s)" in errors_on(changeset).password
    end

    test "rejects invalid token", %{user: _user} do
      assert {:error, :invalid_token} =
               Accounts.reset_password_with_token("invalid_token", %{
                 password: "new_password123",
                 password_confirmation: "new_password123"
               })
    end

    test "token cannot be reused", %{user: user} do
      # Add verified recovery email and initiate password reset
      _user = set_recovery_email_verified(user, "recovery@example.com")
      {:ok, _result} = Accounts.initiate_password_reset(user.username)

      # Get the token from the updated user
      updated_user = Accounts.get_user!(user.id)
      token = updated_user.password_reset_token

      new_password = "new_valid_password123"

      # First reset should work
      assert {:ok, _user} =
               Accounts.reset_password_with_token(token, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      # Second attempt with same token should fail
      assert {:error, :invalid_token} =
               Accounts.reset_password_with_token(token, %{
                 password: "another_password123",
                 password_confirmation: "another_password123"
               })
    end
  end
end
