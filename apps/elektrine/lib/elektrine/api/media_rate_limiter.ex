defmodule Elektrine.API.MediaRateLimiter do
  @moduledoc """
  Rate limiting for media upload and metadata API endpoints.
  """

  use Elektrine.RateLimiter,
    table: :api_media_rate_limiter,
    limits: [
      {:minute, 10},
      {:hour, 120}
    ],
    lockout: {:minutes, 15},
    cleanup_interval: {:minutes, 5}
end
