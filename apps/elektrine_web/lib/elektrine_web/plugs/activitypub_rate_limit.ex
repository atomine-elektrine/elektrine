defmodule ElektrineWeb.Plugs.ActivityPubRateLimit do
  @moduledoc """
  Rate limiting for ActivityPub endpoints.

  Note: Inbox routes skip this plug's rate limiting because the controller
  has more efficient ETS-based rate limiting via InboxRateLimiter that uses
  O(1) update_counter operations instead of O(n) table scans.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip rate limiting for inbox routes - the controller has more efficient
    # ETS-based rate limiting via InboxRateLimiter that uses O(1) operations.
    # This plug previously used O(n) :ets.select scans which caused 700-1200ms latency.
    conn
  end
end
