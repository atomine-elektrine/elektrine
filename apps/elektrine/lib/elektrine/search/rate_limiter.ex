defmodule Elektrine.Search.RateLimiter do
  @moduledoc """
  Read-path rate limiting for global search and live suggestions.

  Limits are tuned for interactive typing while still bounding runaway loops.
  """

  use Elektrine.RateLimiter,
    table: :search_rate_limiter,
    limits: [
      {:minute, 200},
      {:hour, 4000}
    ],
    lockout: {:minutes, 2},
    cleanup_interval: {:minutes, 2}

  @doc """
  Checks and records a search read in one call.
  Returns :ok when allowed, or {:error, retry_after_seconds} when limited.
  """
  def allow_query(identifier) do
    if :ets.whereis(:search_rate_limiter) == :undefined do
      :ok
    else
      case check_rate_limit(identifier) do
        {:ok, :allowed} ->
          record_attempt(identifier)
          :ok

        {:error, {:rate_limited, retry_after, _reason}} ->
          {:error, retry_after}
      end
    end
  rescue
    ArgumentError ->
      :ok
  end
end
