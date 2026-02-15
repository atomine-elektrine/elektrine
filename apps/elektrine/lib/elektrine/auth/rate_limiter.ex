defmodule Elektrine.Auth.RateLimiter do
  @moduledoc """
  Handles authentication rate limiting to prevent brute force attacks.
  Uses ETS for fast in-memory tracking of login attempts.

  Limits:
  - 5 attempts per minute
  - 10 attempts per hour
  - 30-minute lockout after exceeding hourly limit
  """

  use Elektrine.RateLimiter,
    table: :auth_rate_limiter,
    limits: [
      {:minute, 5},
      {:hour, 10}
    ],
    lockout: {:minutes, 30},
    cleanup_interval: {:minutes, 5}

  # Backwards compatibility aliases
  def record_failed_attempt(identifier), do: record_attempt(identifier)
  def record_successful_attempt(identifier), do: clear_limits(identifier)
  def get_rate_limit_status(identifier), do: get_status(identifier)
end
