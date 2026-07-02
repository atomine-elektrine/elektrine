defmodule Elektrine.API.SearchRateLimiter do
  @moduledoc """
  Stricter rate limiting for expensive API search and lookup endpoints.
  """

  use Elektrine.RateLimiter,
    table: :api_search_rate_limiter,
    limits: [
      {:minute, 20},
      {:hour, 300}
    ],
    lockout: {:minutes, 10},
    cleanup_interval: {:minutes, 5}
end
