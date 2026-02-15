defmodule Elektrine.DAV.RateLimiter do
  @moduledoc """
  Rate limiting for CalDAV/CardDAV endpoints.

  DAV clients (iOS, macOS, Thunderbird, DAVx5) sync frequently,
  so limits are more generous than API limits but still protect
  against abuse.

  Limits:
  - 120 requests per minute (DAV clients batch sync operations)
  - 2000 requests per hour
  - 15-minute lockout after exceeding limits
  """

  use Elektrine.RateLimiter,
    table: :dav_rate_limiter,
    limits: [
      {:minute, 120},
      {:hour, 2000}
    ],
    lockout: {:minutes, 15},
    cleanup_interval: {:minutes, 5}
end
