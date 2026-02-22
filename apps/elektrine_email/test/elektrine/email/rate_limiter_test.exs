defmodule Elektrine.Email.RateLimiterTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Email
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Repo

  describe "rate limiting" do
    setup do
      # Create a test user and mailbox
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      # Clear any existing rate limit data
      RateLimiter.clear_limits(user.id)

      %{user: user, mailbox: mailbox}
    end

    test "check_rate_limit returns ok when under limit", %{user: user} do
      # New TL0 user on day 1 has day_limit of 5
      assert {:ok, remaining} = RateLimiter.check_rate_limit(user.id)
      assert remaining == 5
    end

    test "check_rate_limit returns error when minute limit exceeded", %{user: user} do
      # day_1 tier has minute_limit of 1
      # Record 1 attempt to hit the limit
      RateLimiter.record_attempt(user.id)

      assert {:error, :minute_limit_exceeded} = RateLimiter.check_rate_limit(user.id)
    end

    test "check_rate_limit returns error when daily limit exceeded", %{user: user} do
      # day_1 tier has day_limit of 5 and hour_limit of 5
      # Record 5 attempts spread across different hours to hit daily limit (not hourly)
      now = System.system_time(:second)

      for i <- 1..5 do
        # Spread attempts across different hours to avoid hourly limit
        # Each attempt ~1 hour apart
        timestamp = now - i * 3700

        case :ets.lookup(:email_rate_limiter, user.id) do
          [] -> :ets.insert(:email_rate_limiter, {user.id, [timestamp]})
          [{_, attempts}] -> :ets.insert(:email_rate_limiter, {user.id, [timestamp | attempts]})
        end
      end

      assert {:error, :daily_limit_exceeded} = RateLimiter.check_rate_limit(user.id)
    end

    test "get_rate_limit_status returns correct status for new user", %{user: user} do
      status = RateLimiter.get_rate_limit_status(user.id)

      # New TL0 user on day 1 has limits of {1, 5, 5, 3}
      assert status.daily.sent == 0
      assert status.daily.limit == 5
      assert status.daily.remaining == 5
      assert status.tier == :day_1
    end

    test "get_rate_limit_status tracks recorded attempts", %{user: user} do
      # Record some attempts
      RateLimiter.record_attempt(user.id)
      RateLimiter.record_attempt(user.id)

      status = RateLimiter.get_rate_limit_status(user.id)

      assert status.daily.sent == 2
      assert status.daily.limit == 5
      assert status.daily.remaining == 3
    end
  end

  describe "violation tracking and account restriction" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "violationuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      RateLimiter.clear_limits(user.id)

      %{user: user}
    end

    test "record_violation increments violation count", %{user: user} do
      # Record a violation
      :ok = RateLimiter.record_violation(user.id, :minute_limit_exceeded)
      # Give async task time to complete
      Process.sleep(100)

      user = Repo.get!(User, user.id)
      assert user.email_rate_limit_violations == 1
      assert user.email_sending_restricted == false
    end

    test "account is restricted after 3 violations", %{user: user} do
      # Record 3 violations to hit the threshold
      # Use longer delays to avoid race conditions in async task processing
      :ok = RateLimiter.record_violation(user.id, :minute_limit_exceeded)
      Process.sleep(200)
      :ok = RateLimiter.record_violation(user.id, :hourly_limit_exceeded)
      Process.sleep(200)
      :ok = RateLimiter.record_violation(user.id, :daily_limit_exceeded)
      # Give async tasks time to complete
      Process.sleep(200)

      user = Repo.get!(User, user.id)
      assert user.email_rate_limit_violations == 3
      assert user.email_sending_restricted == true
      assert user.email_restriction_reason =~ "Repeated rate limit violations"
      assert user.email_restricted_at != nil
    end

    test "check_account_restricted returns error for restricted user", %{user: user} do
      # Manually restrict the user
      user
      |> Ecto.Changeset.change(%{email_sending_restricted: true})
      |> Repo.update!()

      assert {:error, :account_restricted} = RateLimiter.check_account_restricted(user.id)
    end

    test "check_account_restricted returns ok for non-restricted user", %{user: user} do
      assert :ok = RateLimiter.check_account_restricted(user.id)
    end

    test "check_rate_limit returns account_restricted for restricted user", %{user: user} do
      # Manually restrict the user
      user
      |> Ecto.Changeset.change(%{email_sending_restricted: true})
      |> Repo.update!()

      assert {:error, :account_restricted} = RateLimiter.check_rate_limit(user.id)
    end

    test "lift_restriction clears restriction and violations", %{user: user} do
      # First restrict the user
      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        email_rate_limit_violations: 5,
        email_restriction_reason: "Test restriction",
        email_restricted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      # Lift the restriction
      assert {:ok, updated_user} = RateLimiter.lift_restriction(user.id)

      assert updated_user.email_sending_restricted == false
      assert updated_user.email_rate_limit_violations == 0
      assert updated_user.email_restriction_reason == nil
      assert updated_user.email_restricted_at == nil
    end

    test "lift_restriction returns error for non-existent user" do
      assert {:error, :not_found} = RateLimiter.lift_restriction(-1)
    end

    test "get_restriction_status returns correct status for restricted user", %{user: user} do
      # Set up a restricted user with recovery email
      user
      |> Ecto.Changeset.change(%{
        email_sending_restricted: true,
        email_rate_limit_violations: 3,
        email_restriction_reason: "Repeated rate limit violations",
        email_restricted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        recovery_email: "recovery@example.com",
        recovery_email_verified: false
      })
      |> Repo.update!()

      status = RateLimiter.get_restriction_status(user.id)

      assert status.restricted == true
      assert status.violations == 3
      assert status.reason == "Repeated rate limit violations"
      assert status.restricted_at != nil
      assert status.recovery_email == "recovery@example.com"
      assert status.recovery_email_verified == false
    end

    test "get_restriction_status returns default for non-existent user" do
      status = RateLimiter.get_restriction_status(-1)

      assert status.restricted == false
      assert status.violations == 0
      assert status.reason == nil
    end
  end

  describe "tier selection" do
    test "new TL0 user gets day_1 tier" do
      {:ok, user} =
        Accounts.create_user(%{
          username: "newuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      status = RateLimiter.get_status(user.id)
      assert status.tier == :day_1
      # day_1 limits: {1, 5, 5, 3}
      assert status.attempts[86_400].limit == 5
      assert status.attempts[3600].limit == 5
      assert status.attempts[60].limit == 1
    end

    test "TL1 user gets tl1 tier" do
      {:ok, user} =
        Accounts.create_user(%{
          username: "tl1user#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      # Upgrade to TL1
      user
      |> Ecto.Changeset.change(%{trust_level: 1})
      |> Repo.update!()

      status = RateLimiter.get_status(user.id)
      assert status.tier == :tl1
      # tl1 limits: {5, 50, 200, 50}
      assert status.attempts[86_400].limit == 200
      assert status.attempts[3600].limit == 50
      assert status.attempts[60].limit == 5
    end

    test "TL3 user gets tl3_plus tier" do
      {:ok, user} =
        Accounts.create_user(%{
          username: "tl3user#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      # Upgrade to TL3
      user
      |> Ecto.Changeset.change(%{trust_level: 3})
      |> Repo.update!()

      status = RateLimiter.get_status(user.id)
      assert status.tier == :tl3_plus
      # tl3_plus limits: {15, 150, 1000, 200}
      assert status.attempts[86_400].limit == 1000
      assert status.attempts[3600].limit == 150
      assert status.attempts[60].limit == 15
    end
  end

  describe "recipient limiting" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "recipientuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      RateLimiter.clear_limits(user.id)

      %{user: user}
    end

    test "check_recipient_limit allows sending to new recipient under limit", %{user: user} do
      assert {:ok, :allowed} = RateLimiter.check_recipient_limit(user.id, "test@example.com")
    end

    test "check_recipient_limit allows sending to same recipient multiple times", %{user: user} do
      # Record the recipient
      RateLimiter.record_recipient(user.id, "test@example.com")

      # Should still be allowed since it's the same recipient
      assert {:ok, :allowed} = RateLimiter.check_recipient_limit(user.id, "test@example.com")
    end

    test "check_recipient_limit blocks when unique recipient limit exceeded", %{user: user} do
      # day_1 tier has recipient_limit of 3
      # Record 3 different recipients
      RateLimiter.record_recipient(user.id, "recipient1@example.com")
      RateLimiter.record_recipient(user.id, "recipient2@example.com")
      RateLimiter.record_recipient(user.id, "recipient3@example.com")

      # Should be blocked for a 4th unique recipient
      assert {:error, :recipient_limit_exceeded} =
               RateLimiter.check_recipient_limit(user.id, "recipient4@example.com")
    end

    test "recipient tracking is case insensitive", %{user: user} do
      RateLimiter.record_recipient(user.id, "Test@Example.com")

      # Same email different case should be allowed
      assert {:ok, :allowed} = RateLimiter.check_recipient_limit(user.id, "test@example.com")
    end
  end
end
