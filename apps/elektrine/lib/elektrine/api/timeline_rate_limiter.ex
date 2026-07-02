defmodule Elektrine.API.TimelineRateLimiter do
  @moduledoc """
  Rate limiting for paginated timeline and status-read API endpoints.
  """

  use Elektrine.RateLimiter,
    table: :api_timeline_rate_limiter,
    limits: [
      {:minute, 40},
      {:hour, 700}
    ],
    lockout: {:minutes, 10},
    cleanup_interval: {:minutes, 5}
end
