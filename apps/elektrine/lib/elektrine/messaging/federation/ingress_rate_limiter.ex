defmodule Elektrine.Messaging.Federation.IngressRateLimiter do
  @moduledoc """
  Per-peer and per-room rate limiting for federation ingress (arblarg 9.4).

  Fixed one-minute windows tracked in ETS keyed on the verified peer domain,
  so checks are a single `:ets.update_counter/4` on the hot path. Buckets:

    * `{:peer, domain, lane}` for the durable, ephemeral, sync (sync +
      snapshot), and replay lanes
    * `{:room, domain, stream_id}` for durable events per origin stream

  Batches are reserved atomically up front: when a batch alone exceeds the
  remaining capacity of any bucket the whole batch is rejected and already
  reserved costs are rolled back, so rejected traffic does not consume budget.

  Checks return `:ok` or `{:error, :rate_limited, retry_after_seconds}` where
  `retry_after_seconds` is the time until the current window resets.
  """

  use GenServer

  alias Elektrine.Messaging.Federation.{Config, Runtime}

  @table __MODULE__
  @window_seconds 60
  @cleanup_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Checks a request-lane limit for a verified peer domain.

  Lanes: `:durable`, `:ephemeral`, `:sync`, `:replay`. `cost` is the number
  of items the request carries (batch size for batched lanes).
  Accepts `now: unix_seconds` in `opts` for deterministic tests.
  """
  def check_peer(domain, lane, cost \\ 1, opts \\ [])

  def check_peer(domain, lane, cost, opts)
      when is_binary(domain) and is_atom(lane) and is_integer(cost) and cost >= 0 do
    check_buckets(domain, [{{:peer, domain, lane}, cost, peer_limit(lane)}], opts)
  end

  def check_peer(_domain, _lane, _cost, _opts), do: :ok

  @doc """
  Checks the durable-event lanes for a batch of events from a verified peer.

  `stream_ids` carries one entry per event (entries that are not binaries
  still count against the per-peer bucket but skip per-room accounting).
  Reserves the per-peer durable bucket plus a per-room bucket for each
  `(domain, stream_id)` pair; rejects the whole batch when any bucket lacks
  capacity. Accepts `now: unix_seconds` in `opts` for deterministic tests.
  """
  def check_durable(domain, stream_ids, opts \\ [])

  def check_durable(domain, stream_ids, opts) when is_binary(domain) and is_list(stream_ids) do
    room_limit = config_value(:ingress_room_durable_events_per_minute)

    room_buckets =
      stream_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.map(fn {stream_id, cost} -> {{:room, domain, stream_id}, cost, room_limit} end)

    buckets = [{{:peer, domain, :durable}, length(stream_ids), peer_limit(:durable)}]

    check_buckets(domain, buckets ++ room_buckets, opts)
  end

  def check_durable(_domain, _stream_ids, _opts), do: :ok

  @doc "Clears all rate limit state (test support)."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(@cleanup_interval_ms, self(), :cleanup)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = window_index(System.system_time(:second)) - 1

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    {:noreply, state}
  end

  # Internal helpers

  defp check_buckets(domain, buckets, opts) do
    if enabled?() and not exempt_domain?(domain) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      reserve_all(buckets, window_index(now), [], now)
    else
      :ok
    end
  end

  defp reserve_all([], _window, _taken, _now), do: :ok

  defp reserve_all([{key, cost, limit} | rest], window, taken, now) do
    if reserve(key, window, cost, limit) do
      reserve_all(rest, window, [{key, cost} | taken], now)
    else
      Enum.each(taken, fn {taken_key, taken_cost} ->
        :ets.update_counter(@table, {taken_key, window}, {2, -taken_cost})
      end)

      {:error, :rate_limited, retry_after_seconds(now)}
    end
  end

  defp reserve(key, window, cost, limit) do
    counter_key = {key, window}
    count = :ets.update_counter(@table, counter_key, {2, cost}, {counter_key, 0})

    if count > limit do
      :ets.update_counter(@table, counter_key, {2, -cost})
      false
    else
      true
    end
  end

  defp window_index(now), do: div(now, @window_seconds)

  defp retry_after_seconds(now), do: @window_seconds - rem(now, @window_seconds)

  defp peer_limit(:durable), do: config_value(:ingress_peer_durable_events_per_minute)
  defp peer_limit(:ephemeral), do: config_value(:ingress_peer_ephemeral_items_per_minute)
  defp peer_limit(:sync), do: config_value(:ingress_peer_sync_requests_per_minute)
  defp peer_limit(:replay), do: config_value(:ingress_peer_replay_requests_per_minute)

  defp config_value(key), do: Config.ingress_rate_limit(Runtime.federation_config(), key)

  defp enabled? do
    Config.ingress_rate_limit_enabled?(Runtime.federation_config())
  end

  defp exempt_domain?(domain) do
    domain
    |> String.downcase()
    |> then(&(&1 in Config.ingress_rate_limit_exempt_domains(Runtime.federation_config())))
  end
end
