defmodule Elektrine.Search.PaigeRateLimiter do
  @moduledoc """
  Bounds requests that fan out to Paige's external search providers.

  This limiter is intentionally separate from local search suggestions: a
  remote meta-search can consume paid API quota and considerably more work.
  """

  use Elektrine.RateLimiter,
    table: :paige_search_rate_limiter,
    limits: [
      {:minute, 30},
      {:hour, 500}
    ],
    lockout: {:minutes, 2},
    cleanup_interval: {:minutes, 2}

  # Use the calling process as the lock requester. A shared requester ID makes
  # :global treat concurrent calls as re-entrant, defeating atomic admission.
  def check_and_record(identifier) do
    :global.trans({{__MODULE__, identifier}, self()}, fn ->
      case check_rate_limit(identifier) do
        {:ok, :allowed} = result ->
          record_attempt(identifier)
          result

        error ->
          error
      end
    end)
  end

  @doc "Atomically checks and records one external Paige search."
  def allow_query(identifier) do
    if :ets.whereis(:paige_search_rate_limiter) == :undefined do
      :ok
    else
      case check_and_record(identifier) do
        {:ok, :allowed} -> :ok
        {:error, {:rate_limited, retry_after, _reason}} -> {:error, retry_after}
        _unexpected -> :ok
      end
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end
end
