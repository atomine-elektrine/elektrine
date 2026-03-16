defmodule Elektrine.Accounts.RecoveryEmailVerificationTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Accounts.RecoveryEmailVerification
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  defmodule FailingMailerAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config), do: {:error, :forced_failure}
    def deliver_many(_emails, _config), do: {:error, :forced_failure}
  end

  describe "send_verification_email/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "recoveryuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns error for non-existent user" do
      assert {:error, :user_not_found} = RecoveryEmailVerification.send_verification_email(-1)
    end

    test "returns error when no recovery email is set", %{user: user} do
      # User has no recovery email
      assert {:error, :no_recovery_email} =
               RecoveryEmailVerification.send_verification_email(user.id)
    end

    test "returns already_verified when recovery email is already verified", %{user: user} do
      # Set up user with verified recovery email (not restricted)
      user
      |> Ecto.Changeset.change(%{
        recovery_email: "recovery@example.com",
        recovery_email_verified: true
      })
      |> Repo.update!()

      assert {:error, :already_verified} =
               RecoveryEmailVerification.send_verification_email(user.id)
    end

    test "sends verification for restricted user with verified email (to lift restriction)", %{
      user: user
    } do
      # Set up user with restriction and verified recovery email
      # In this case, we still send to help lift restriction
      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verified: true
      })
      |> Repo.update!()

      # Should send verification email (because user is restricted)
      assert {:ok, updated_user} = RecoveryEmailVerification.send_verification_email(user.id)
      assert updated_user.recovery_email_verification_token != nil
      assert String.length(updated_user.recovery_email_verification_token) == 64
      refute updated_user.recovery_email_verification_token == extract_verification_token()
    end

    test "sends verification email and generates token", %{user: user} do
      # Set up user with restriction and recovery email
      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verified: false
      })
      |> Repo.update!()

      assert {:ok, updated_user} = RecoveryEmailVerification.send_verification_email(user.id)
      assert updated_user.recovery_email_verification_token != nil
      assert String.length(updated_user.recovery_email_verification_token) == 64
      assert updated_user.recovery_email_verification_sent_at != nil
      refute updated_user.recovery_email_verification_token == extract_verification_token()
    end

    test "returns error and restores previous verification state when email delivery fails", %{
      user: user
    } do
      previous_mailer_config = Application.get_env(:elektrine, Elektrine.Mailer, [])

      on_exit(fn ->
        Application.put_env(:elektrine, Elektrine.Mailer, previous_mailer_config)
      end)

      Application.put_env(
        :elektrine,
        Elektrine.Mailer,
        Keyword.put(previous_mailer_config, :adapter, FailingMailerAdapter)
      )

      old_token = "old_verification_token_#{System.unique_integer([:positive])}"
      old_sent_at = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(%{
        recovery_email: "recovery@example.com",
        recovery_email_verified: false,
        recovery_email_verification_token: User.hash_sensitive_token(old_token),
        recovery_email_verification_sent_at: old_sent_at
      })
      |> Repo.update!()

      assert {:error, :email_failed} =
               RecoveryEmailVerification.send_verification_email(user.id, force: true)

      reloaded_user = Accounts.get_user!(user.id)

      assert reloaded_user.recovery_email_verification_token ==
               User.hash_sensitive_token(old_token)

      assert reloaded_user.recovery_email_verification_sent_at == old_sent_at
      refute_received {:email, _}
    end
  end

  describe "verify_token/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "verifyuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns error for nil token" do
      assert {:error, :invalid_token} = RecoveryEmailVerification.verify_token(nil)
    end

    test "returns error for empty token" do
      assert {:error, :invalid_token} = RecoveryEmailVerification.verify_token("")
    end

    test "returns error for non-existent token" do
      assert {:error, :invalid_token} =
               RecoveryEmailVerification.verify_token("nonexistent_token")
    end

    test "returns error for expired token", %{user: user} do
      # Set up user with expired token (sent 25 hours ago)
      expired_time =
        DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verification_token: User.hash_sensitive_token("expired_token_123"),
        recovery_email_verification_sent_at: expired_time
      })
      |> Repo.update!()

      assert {:error, :token_expired} =
               RecoveryEmailVerification.verify_token("expired_token_123")
    end

    test "successfully verifies valid token and lifts restriction", %{user: user} do
      # Set up user with valid token
      token = "valid_token_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        email_rate_limit_violations: 3,
        email_restriction_reason: "Test restriction",
        email_restricted_at: now,
        recovery_email: "recovery@example.com",
        recovery_email_verified: false,
        recovery_email_verification_token: User.hash_sensitive_token(token),
        recovery_email_verification_sent_at: now
      })
      |> Repo.update!()

      assert {:ok, updated_user} = RecoveryEmailVerification.verify_token(token)

      # Check all fields are properly updated
      assert updated_user.recovery_email_verified == true
      assert updated_user.recovery_email_verification_token == nil
      assert updated_user.recovery_email_verification_sent_at == nil
      assert updated_user.email_sending_restricted == false
      assert updated_user.email_rate_limit_violations == 0
      assert updated_user.email_restriction_reason == nil
      assert updated_user.email_restricted_at == nil
    end

    test "token sent 23 hours ago is still valid", %{user: user} do
      # Token sent 23 hours ago should still be valid (under 24 hour limit)
      valid_time =
        DateTime.utc_now() |> DateTime.add(-23 * 3600, :second) |> DateTime.truncate(:second)

      token = "recent_token_#{System.unique_integer([:positive])}"

      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        recovery_email: "recovery@example.com",
        recovery_email_verification_token: User.hash_sensitive_token(token),
        recovery_email_verification_sent_at: valid_time
      })
      |> Repo.update!()

      assert {:ok, _updated_user} = RecoveryEmailVerification.verify_token(token)
    end
  end

  describe "needs_verification?/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "needsverify#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns false for non-existent user" do
      assert RecoveryEmailVerification.needs_verification?(-1) == false
    end

    test "returns false when user has no recovery email", %{user: user} do
      # User has no recovery email set
      assert RecoveryEmailVerification.needs_verification?(user.id) == false
    end

    test "returns true when user has recovery email but not verified", %{user: user} do
      user
      |> Ecto.Changeset.change(%{
        recovery_email: "recovery@example.com",
        recovery_email_verified: false
      })
      |> Repo.update!()

      assert RecoveryEmailVerification.needs_verification?(user.id) == true
    end

    test "returns false when recovery email is verified", %{user: user} do
      user
      |> Ecto.Changeset.change(%{
        recovery_email: "recovery@example.com",
        recovery_email_verified: true
      })
      |> Repo.update!()

      assert RecoveryEmailVerification.needs_verification?(user.id) == false
    end
  end

  describe "set_recovery_email/2" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "setrecovery#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns error for non-existent user" do
      assert {:error, :user_not_found} =
               RecoveryEmailVerification.set_recovery_email(-1, "test@example.com")
    end

    test "sets recovery email and marks as unverified", %{user: user} do
      assert {:ok, updated_user} =
               RecoveryEmailVerification.set_recovery_email(user.id, "new_recovery@example.com")

      assert updated_user.recovery_email == "new_recovery@example.com"
      assert updated_user.recovery_email_verified == false
    end

    test "updating recovery email resets verified status", %{user: user} do
      # First set and verify a recovery email
      user
      |> Ecto.Changeset.change(%{
        recovery_email: "old@example.com",
        recovery_email_verified: true
      })
      |> Repo.update!()

      # Now update to new email
      assert {:ok, updated_user} =
               RecoveryEmailVerification.set_recovery_email(user.id, "new@example.com")

      assert updated_user.recovery_email == "new@example.com"
      assert updated_user.recovery_email_verified == false
    end
  end

  defp extract_verification_token do
    assert_received {:email, email}

    [_, token] = Regex.run(~r{/verify-recovery-email\?token=([A-Za-z0-9_-]+)}, email.text_body)
    token
  end
end
