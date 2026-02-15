defmodule Elektrine.Webhook.RateLimiter do
  @moduledoc """
  Rate limiter for webhook endpoints (Postal, Haraka).
  Limits requests per IP address to prevent abuse.
  """

  use Elektrine.RateLimiter,
    table: :webhook_rate_limit,
    limits: [
      # 1000 requests per minute per IP
      {:minute, 1000}
    ],
    # No lockout for webhooks, just deny
    lockout: nil,
    cleanup_interval: {:minutes, 2}
end
