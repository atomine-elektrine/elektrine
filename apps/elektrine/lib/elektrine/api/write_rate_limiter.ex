defmodule Elektrine.API.WriteRateLimiter do
  @moduledoc """
  Rate limiting for write-heavy compatible API actions.
  """

  use Elektrine.RateLimiter,
    table: :api_write_rate_limiter,
    limits: [
      {:minute, 30},
      {:hour, 500}
    ],
    lockout: {:minutes, 10},
    cleanup_interval: {:minutes, 5}
end
