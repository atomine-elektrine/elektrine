defmodule Elektrine.SMTP.RateLimiter do
  @moduledoc """
  Rate limiter for SMTP authentication attempts.

  Limits:
  - 3 attempts per minute
  - 15 attempts per hour
  - 15-minute block after exceeding limit (increased from 5)
  """

  use Elektrine.RateLimiter,
    table: :smtp_rate_limiter,
    limits: [
      {:minute, 3},
      {:hour, 15}
    ],
    lockout: {:minutes, 15},
    cleanup_interval: {:minutes, 1}

  # Backwards compatibility
  def check_attempt(ip) do
    case check_rate_limit(ip) do
      # Return attempts left
      {:ok, :allowed} ->
        status = get_status(ip)
        remaining = get_in(status.attempts, [60, :remaining]) || 0
        {:ok, remaining}

      {:error, {:rate_limited, _retry_after, :locked_out}} ->
        {:error, :blocked}

      {:error, {:rate_limited, _retry_after, _reason}} ->
        {:error, :rate_limited}
    end
  end

  def record_failure(ip), do: record_attempt(ip)
  def clear_attempts(ip), do: clear_limits(ip)
end
