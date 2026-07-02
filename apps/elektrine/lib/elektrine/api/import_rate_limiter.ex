defmodule Elektrine.API.ImportRateLimiter do
  @moduledoc """
  Rate limiting for bulk import endpoints.
  """

  use Elektrine.RateLimiter,
    table: :api_import_rate_limiter,
    limits: [
      {:minute, 3},
      {:hour, 20}
    ],
    lockout: {:minutes, 30},
    cleanup_interval: {:minutes, 5}
end
