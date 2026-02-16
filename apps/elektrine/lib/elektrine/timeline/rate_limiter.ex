defmodule Elektrine.Timeline.RateLimiter do
  @moduledoc """
  Read-path rate limiter for timeline-style endpoints and LiveView tab switching.

  Limits are intentionally generous so normal scrolling and filter switching
  remain smooth while bursts and loops are bounded.
  """

  use Elektrine.RateLimiter,
    table: :timeline_rate_limiter,
    limits: [
      {:minute, 180},
      {:hour, 4000}
    ],
    lockout: {:minutes, 2},
    cleanup_interval: {:minutes, 2}

  @doc """
  Checks and records a timeline read in one call.
  Returns :ok when allowed, or {:error, retry_after_seconds} when limited.
  """
  def allow_read(identifier) do
    case check_rate_limit(identifier) do
      {:ok, :allowed} ->
        record_attempt(identifier)
        :ok

      {:error, {:rate_limited, retry_after, _reason}} ->
        {:error, retry_after}
    end
  end
end
