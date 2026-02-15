defmodule Elektrine.API.RateLimiter do
  @moduledoc """
  Rate limiting for API endpoints to prevent abuse.
  Uses ETS for fast in-memory tracking.

  Limits:
  - 60 requests per minute
  - 1000 requests per hour
  - 15-minute lockout after exceeding limits
  """

  use Elektrine.RateLimiter,
    table: :api_rate_limiter,
    limits: [
      {:minute, 60},
      {:hour, 1000}
    ],
    lockout: {:minutes, 15},
    cleanup_interval: {:minutes, 5}
end
