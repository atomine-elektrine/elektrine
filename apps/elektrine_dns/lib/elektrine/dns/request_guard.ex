defmodule Elektrine.DNS.RequestGuard do
  @moduledoc false

  use GenServer

  alias Elektrine.DNS

  @table __MODULE__
  @cleanup_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def begin_request(client_ip, transport) when transport in [:udp, :tcp] do
    bucket = current_bucket()
    client_key = normalize_client_key(client_ip)
    rate_key = {:rate, transport, bucket, client_key}

    count = :ets.update_counter(@table, rate_key, {2, 1}, {rate_key, 0})

    if count > rate_limit(transport) do
      {:error, :rate_limited}
    else
      inflight_key = {:inflight, transport}
      inflight = :ets.update_counter(@table, inflight_key, {2, 1}, {inflight_key, 0})

      if inflight > max_inflight(transport) do
        :ets.update_counter(@table, inflight_key, {2, -1})
        {:error, :busy}
      else
        {:ok, transport}
      end
    end
  end

  def finish_request(transport) when transport in [:udp, :tcp] do
    inflight_key = {:inflight, transport}

    try do
      :ets.update_counter(@table, inflight_key, {2, -1})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_buckets()
    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup_old_buckets do
    cutoff_bucket = current_bucket() - 2

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {{:rate, _transport, bucket, _client_key} = key, _count} when bucket < cutoff_bucket ->
        :ets.delete(@table, key)

      _ ->
        :ok
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp current_bucket do
    DNS.rate_limit_window_ms()
    |> max(1)
    |> then(&(System.monotonic_time(:millisecond) |> div(&1)))
  end

  defp normalize_client_key(nil), do: :unknown
  defp normalize_client_key(client_ip), do: client_ip

  defp rate_limit(:udp), do: max(DNS.udp_rate_limit_per_window(), 1)
  defp rate_limit(:tcp), do: max(DNS.tcp_rate_limit_per_window(), 1)

  defp max_inflight(:udp), do: max(DNS.udp_max_inflight(), 1)
  defp max_inflight(:tcp), do: max(DNS.tcp_max_inflight(), 1)
end
