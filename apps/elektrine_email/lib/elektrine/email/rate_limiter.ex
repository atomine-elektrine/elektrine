defmodule Elektrine.Email.RateLimiter do
  @moduledoc """
  Handles email sending rate limiting with tiered limits based on trust level and account age.

  ## Warmup Period (TL0 accounts)

  Day 1:
  - 1 email per minute, 5 per hour, 5 per day, 3 recipients

  Days 2-3:
  - 2 emails per minute, 8 per hour, 10 per day, 5 recipients

  Days 4-7:
  - 2 emails per minute, 15 per hour, 20 per day, 10 recipients

  Week 2 (days 8-14):
  - 3 emails per minute, 25 per hour, 35 per day, 15 recipients

  Weeks 3-4 (days 15-30):
  - 3 emails per minute, 35 per hour, 50 per day, 20 recipients

  ## Trust Level Tiers (override warmup)

  TL1 (Basic trust):
  - 5 emails per minute
  - 50 emails per hour
  - 200 emails per day
  - 50 unique recipients per day

  TL2 (Member):
  - 10 emails per minute
  - 100 emails per hour
  - 500 emails per day
  - 100 unique recipients per day

  TL3+ (Regular/Leader):
  - 15 emails per minute
  - 150 emails per hour
  - 1000 emails per day
  - 200 unique recipients per day
  """

  use GenServer
  require Logger

  @table_name :email_rate_limiter
  @recipient_table :email_recipient_limiter
  @cleanup_interval :timer.minutes(5)

  # Tier definitions: {minute_limit, hour_limit, day_limit, recipient_limit}
  @tier_limits %{
    # Warmup tiers for TL0 accounts (very restrictive initially)
    day_1: {1, 5, 5, 3},
    days_2_3: {2, 8, 10, 5},
    days_4_7: {2, 15, 20, 10},
    week_2: {3, 25, 35, 15},
    weeks_3_4: {3, 35, 50, 20},
    # Trust level tiers (override warmup)
    tl1: {5, 50, 200, 50},
    tl2: {10, 100, 500, 100},
    tl3_plus: {15, 150, 1000, 200}
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@recipient_table, [:named_table, :public, :set])

    # Schedule cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  # Number of violations before account is restricted
  @violation_threshold 3

  @doc """
  Checks if a user can send an email based on their tier limits.

  Returns:
  - `{:ok, remaining}` - Can send, returns remaining daily quota
  - `{:error, :minute_limit_exceeded}` - Hit per-minute limit
  - `{:error, :hourly_limit_exceeded}` - Hit hourly limit
  - `{:error, :daily_limit_exceeded}` - Hit daily limit
  - `{:error, :recipient_limit_exceeded}` - Hit unique recipient limit
  - `{:error, :account_restricted}` - Account is restricted due to repeated violations
  """
  def check_rate_limit(user_id) do
    # First check if account is restricted
    case check_account_restricted(user_id) do
      {:error, :account_restricted} = error ->
        error

      :ok ->
        do_check_rate_limit(user_id)
    end
  end

  defp do_check_rate_limit(user_id) do
    tier = get_user_tier(user_id)
    {minute_limit, hour_limit, day_limit, _recipient_limit} = Map.get(@tier_limits, tier)

    now = System.system_time(:second)
    attempts = get_attempts(user_id)

    minute_count = count_recent(attempts, now, 60)
    hour_count = count_recent(attempts, now, 3600)
    day_count = count_recent(attempts, now, 86_400)

    cond do
      minute_count >= minute_limit ->
        Logger.warning(
          "User #{user_id} (#{tier}) exceeded minute limit: #{minute_count}/#{minute_limit}"
        )

        record_violation(user_id, :minute_limit_exceeded)
        {:error, :minute_limit_exceeded}

      hour_count >= hour_limit ->
        Logger.warning(
          "User #{user_id} (#{tier}) exceeded hourly limit: #{hour_count}/#{hour_limit}"
        )

        record_violation(user_id, :hourly_limit_exceeded)
        {:error, :hourly_limit_exceeded}

      day_count >= day_limit ->
        Logger.warning(
          "User #{user_id} (#{tier}) exceeded daily limit: #{day_count}/#{day_limit}"
        )

        record_violation(user_id, :daily_limit_exceeded)
        {:error, :daily_limit_exceeded}

      true ->
        {:ok, day_limit - day_count}
    end
  end

  @doc """
  Checks if a user's account is restricted from sending emails.
  """
  def check_account_restricted(user_id) do
    case Elektrine.Repo.get(Elektrine.Accounts.User, user_id) do
      nil ->
        :ok

      user ->
        if user.email_sending_restricted do
          {:error, :account_restricted}
        else
          :ok
        end
    end
  end

  @doc """
  Records a rate limit violation for a user.
  After #{@violation_threshold} violations, the account is restricted.
  """
  def record_violation(user_id, violation_type) do
    Elektrine.Async.run(fn ->
      case Elektrine.Repo.get(Elektrine.Accounts.User, user_id) do
        nil ->
          :ok

        user ->
          new_count = (user.email_rate_limit_violations || 0) + 1

          changes = %{email_rate_limit_violations: new_count}

          # Restrict account after threshold violations
          changes =
            if new_count >= @violation_threshold do
              Logger.warning(
                "User #{user_id} has #{new_count} rate limit violations - restricting email sending"
              )

              Map.merge(changes, %{
                email_sending_restricted: true,
                email_restriction_reason: "Repeated rate limit violations (#{violation_type})",
                email_restricted_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
            else
              changes
            end

          user
          |> Ecto.Changeset.change(changes)
          |> Elektrine.Repo.update()
      end
    end)

    :ok
  end

  @doc """
  Lifts email sending restriction for a user (after recovery email verification).
  """
  def lift_restriction(user_id) do
    case Elektrine.Repo.get(Elektrine.Accounts.User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Ecto.Changeset.change(%{
          email_sending_restricted: false,
          email_rate_limit_violations: 0,
          email_restriction_reason: nil,
          email_restricted_at: nil
        })
        |> Elektrine.Repo.update()
    end
  end

  @doc """
  Gets the restriction status for a user.
  """
  def get_restriction_status(user_id) do
    case Elektrine.Repo.get(Elektrine.Accounts.User, user_id) do
      nil ->
        %{restricted: false, violations: 0, reason: nil}

      user ->
        %{
          restricted: user.email_sending_restricted || false,
          violations: user.email_rate_limit_violations || 0,
          reason: user.email_restriction_reason,
          restricted_at: user.email_restricted_at,
          recovery_email: user.recovery_email,
          recovery_email_verified: user.recovery_email_verified || false
        }
    end
  end

  @doc """
  Checks if a user can send to a specific recipient (for unique recipient limiting).

  Returns:
  - `{:ok, :allowed}` - Can send to this recipient
  - `{:error, :recipient_limit_exceeded}` - Hit unique recipient limit
  """
  def check_recipient_limit(user_id, recipient_email) do
    tier = get_user_tier(user_id)
    {_minute_limit, _hour_limit, _day_limit, recipient_limit} = Map.get(@tier_limits, tier)

    now = System.system_time(:second)
    recipients = get_recipients(user_id)

    # Count unique recipients in last 24 hours
    day_cutoff = now - 86_400

    recent_recipients =
      recipients
      |> Enum.filter(fn {_email, timestamp} -> timestamp > day_cutoff end)
      |> Enum.map(fn {email, _timestamp} -> email end)
      |> Enum.uniq()

    # If recipient is already in the list, allow (not a new unique recipient)
    normalized_recipient = String.downcase(recipient_email)

    if normalized_recipient in recent_recipients do
      {:ok, :allowed}
    else
      if length(recent_recipients) >= recipient_limit do
        Logger.warning(
          "User #{user_id} (#{tier}) exceeded recipient limit: #{length(recent_recipients)}/#{recipient_limit}"
        )

        {:error, :recipient_limit_exceeded}
      else
        {:ok, :allowed}
      end
    end
  end

  @doc """
  Records an email send for rate limiting.
  """
  def record_send(user_id) do
    record_attempt(user_id)
  end

  @doc """
  Records a recipient for unique recipient tracking.
  """
  def record_recipient(user_id, recipient_email) do
    now = System.system_time(:second)
    normalized = String.downcase(recipient_email)

    case :ets.lookup(@recipient_table, user_id) do
      [] ->
        :ets.insert(@recipient_table, {user_id, [{normalized, now}]})

      [{^user_id, recipients}] ->
        # Add new recipient and filter old ones (keep last 24 hours)
        cutoff = now - 86_400
        filtered = Enum.filter(recipients, fn {_email, ts} -> ts > cutoff end)
        new_recipients = [{normalized, now} | filtered]
        :ets.insert(@recipient_table, {user_id, new_recipients})
    end

    :ok
  end

  @doc """
  Records an attempt for rate limiting.
  """
  def record_attempt(user_id) do
    now = System.system_time(:second)

    case :ets.lookup(@table_name, user_id) do
      [] ->
        :ets.insert(@table_name, {user_id, [now]})

      [{^user_id, attempts}] ->
        # Add new attempt and filter old ones (keep last 24 hours)
        cutoff = now - 86_400
        filtered = Enum.filter(attempts, fn ts -> ts > cutoff end)
        new_attempts = [now | filtered]
        :ets.insert(@table_name, {user_id, new_attempts})
    end

    :ok
  end

  @doc """
  Clears all rate limiting data for a user.
  """
  def clear_limits(user_id) do
    :ets.delete(@table_name, user_id)
    :ets.delete(@recipient_table, user_id)
    :ok
  end

  @doc """
  Gets the current rate limit status for a user.
  """
  def get_status(user_id) do
    tier = get_user_tier(user_id)
    {minute_limit, hour_limit, day_limit, recipient_limit} = Map.get(@tier_limits, tier)

    now = System.system_time(:second)
    attempts = get_attempts(user_id)
    recipients = get_recipients(user_id)

    day_cutoff = now - 86_400

    unique_recipients =
      recipients
      |> Enum.filter(fn {_email, ts} -> ts > day_cutoff end)
      |> Enum.map(fn {email, _ts} -> email end)
      |> Enum.uniq()
      |> length()

    %{
      tier: tier,
      locked: false,
      locked_until: nil,
      attempts: %{
        60 => %{
          count: count_recent(attempts, now, 60),
          limit: minute_limit,
          remaining: max(0, minute_limit - count_recent(attempts, now, 60))
        },
        3600 => %{
          count: count_recent(attempts, now, 3600),
          limit: hour_limit,
          remaining: max(0, hour_limit - count_recent(attempts, now, 3600))
        },
        86_400 => %{
          count: count_recent(attempts, now, 86_400),
          limit: day_limit,
          remaining: max(0, day_limit - count_recent(attempts, now, 86_400))
        }
      },
      recipients: %{
        count: unique_recipients,
        limit: recipient_limit,
        remaining: max(0, recipient_limit - unique_recipients)
      }
    }
  end

  @doc """
  Gets rate limit status in the legacy format for backwards compatibility.
  """
  def get_rate_limit_status(user_id) do
    status = get_status(user_id)

    %{
      daily: %{
        sent: status.attempts[86_400].count,
        limit: status.attempts[86_400].limit,
        remaining: status.attempts[86_400].remaining
      },
      hourly: %{
        sent: status.attempts[3600].count,
        limit: status.attempts[3600].limit,
        remaining: status.attempts[3600].remaining
      },
      minute: %{
        sent: status.attempts[60].count,
        limit: status.attempts[60].limit,
        remaining: status.attempts[60].remaining
      },
      recipients: %{
        count: status.recipients.count,
        limit: status.recipients.limit,
        remaining: status.recipients.remaining
      },
      tier: status.tier
    }
  end

  # Max possible daily limit (for display purposes)
  def daily_limit, do: 1000

  # Private functions

  defp get_user_tier(user_id) do
    case Elektrine.Repo.get(Elektrine.Accounts.User, user_id) do
      nil ->
        # Default to most restrictive
        :day_1

      user ->
        account_age_days = DateTime.diff(DateTime.utc_now(), user.inserted_at, :day)
        trust_level = user.trust_level || 0

        # Trust levels override warmup period
        cond do
          trust_level >= 3 -> :tl3_plus
          trust_level == 2 -> :tl2
          trust_level == 1 -> :tl1
          # Granular warmup for TL0 accounts
          account_age_days < 1 -> :day_1
          account_age_days < 3 -> :days_2_3
          account_age_days < 7 -> :days_4_7
          account_age_days < 14 -> :week_2
          account_age_days < 30 -> :weeks_3_4
          # After 30 days at TL0, use week 3-4 limits (they need to earn TL1)
          true -> :weeks_3_4
        end
    end
  end

  defp get_attempts(user_id) do
    case :ets.lookup(@table_name, user_id) do
      [] -> []
      [{^user_id, attempts}] -> attempts
    end
  end

  defp get_recipients(user_id) do
    case :ets.lookup(@recipient_table, user_id) do
      [] -> []
      [{^user_id, recipients}] -> recipients
    end
  end

  defp count_recent(attempts, now, window_seconds) do
    cutoff = now - window_seconds
    Enum.count(attempts, fn timestamp -> timestamp > cutoff end)
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)
    # Keep 2 days of data
    cutoff = now - 86_400 * 2

    # Clean up attempt records
    :ets.tab2list(@table_name)
    |> Enum.each(fn {user_id, attempts} ->
      filtered = Enum.filter(attempts, fn ts -> ts > cutoff end)

      if Enum.empty?(filtered) do
        :ets.delete(@table_name, user_id)
      else
        :ets.insert(@table_name, {user_id, filtered})
      end
    end)

    # Clean up recipient records
    :ets.tab2list(@recipient_table)
    |> Enum.each(fn {user_id, recipients} ->
      filtered = Enum.filter(recipients, fn {_email, ts} -> ts > cutoff end)

      if Enum.empty?(filtered) do
        :ets.delete(@recipient_table, user_id)
      else
        :ets.insert(@recipient_table, {user_id, filtered})
      end
    end)
  end
end
