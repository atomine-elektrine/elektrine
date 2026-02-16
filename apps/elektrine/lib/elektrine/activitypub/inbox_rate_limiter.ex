defmodule Elektrine.ActivityPub.InboxRateLimiter do
  @moduledoc """
  Simple rate limiter for ActivityPub inbox to prevent resource exhaustion.
  Uses ETS for fast in-memory tracking.
  """

  use GenServer
  require Logger

  # Default limits can be overridden at runtime via:
  # config :elektrine, Elektrine.ActivityPub.InboxRateLimiter, ...
  @default_max_per_minute 20
  @default_max_per_domain_per_minute 40
  @default_max_global_per_second 8
  # Cleanup interval
  @cleanup_interval 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if request should be allowed.
  Returns {:ok, :allowed} or {:error, :rate_limited}
  """
  def check_rate_limit(ip_address, actor_domain \\ nil) do
    now = System.system_time(:second)
    minute_bucket = div(now, 60)

    max_global_per_second =
      configured_limit(:max_global_per_second, @default_max_global_per_second)

    max_per_domain_per_minute =
      configured_limit(:max_per_domain_per_minute, @default_max_per_domain_per_minute)

    max_per_minute = configured_limit(:max_per_minute, @default_max_per_minute)

    # Check global rate first
    global_count =
      :ets.update_counter(:inbox_rate_limit, {:global, now}, {2, 1}, {{:global, now}, 0})

    cond do
      global_count > max_global_per_second ->
        {:error, :rate_limited}

      # Check per-domain rate (most important - prevents one noisy instance from flooding)
      actor_domain && domain_over_limit?(actor_domain, minute_bucket, max_per_domain_per_minute) ->
        {:error, :rate_limited}

      # Check per-IP rate
      ip_over_limit?(ip_address, minute_bucket, max_per_minute) ->
        {:error, :rate_limited}

      true ->
        {:ok, :allowed}
    end
  end

  defp domain_over_limit?(domain, minute_bucket, max_per_domain_per_minute) do
    count =
      :ets.update_counter(
        :inbox_rate_limit,
        {:domain, domain, minute_bucket},
        {2, 1},
        {{:domain, domain, minute_bucket}, 0}
      )

    count > max_per_domain_per_minute
  end

  defp ip_over_limit?(ip_address, minute_bucket, max_per_minute) do
    count =
      :ets.update_counter(
        :inbox_rate_limit,
        {ip_address, minute_bucket},
        {2, 1},
        {{ip_address, minute_bucket}, 0}
      )

    count > max_per_minute
  end

  @impl true
  def init(_opts) do
    # Create ETS table for rate limiting
    :ets.new(:inbox_rate_limit, [:named_table, :public, :set, {:write_concurrency, true}])

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("InboxRateLimiter started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up old entries
    now = System.system_time(:second)
    current_minute = div(now, 60)

    # Delete entries older than 2 minutes (IP entries)
    :ets.select_delete(:inbox_rate_limit, [
      {{{:"$1", :"$2"}, :_}, [{:is_integer, :"$2"}, {:<, :"$2", current_minute - 2}], [true]},
      # Clean up old global entries
      {{{:global, :"$1"}, :_}, [{:<, :"$1", now - 5}], [true]},
      # Clean up old domain entries
      {{{:domain, :_, :"$1"}, :_}, [{:is_integer, :"$1"}, {:<, :"$1", current_minute - 2}],
       [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp configured_limit(key, default) do
    :elektrine
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
    |> normalize_limit(default)
  end

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_, default), do: default
end
