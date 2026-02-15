defmodule Elektrine.VPN.StatsAggregator do
  @moduledoc """
  GenServer that aggregates VPN statistics in memory.
  Provides fast access to aggregate stats for admin dashboards.
  Periodically flushes to database for persistence.
  """
  use GenServer
  require Logger

  alias Elektrine.VPN

  @flush_interval :timer.minutes(5)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record bandwidth usage for a user config.
  """
  def record_bandwidth(server_id, user_config_id, bytes_sent, bytes_received) do
    GenServer.cast(
      __MODULE__,
      {:record_bandwidth, server_id, user_config_id, bytes_sent, bytes_received}
    )
  end

  @doc """
  Get aggregate stats for all servers.
  Returns: %{total_bandwidth: bytes, active_connections: count, server_stats: [...]}
  """
  def get_aggregate_stats do
    GenServer.call(__MODULE__, :get_aggregate_stats)
  end

  @doc """
  Get stats for a specific server.
  """
  def get_server_stats(server_id) do
    GenServer.call(__MODULE__, {:get_server_stats, server_id})
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic flush to database
    schedule_flush()

    Logger.info("VPN StatsAggregator started")

    {:ok,
     %{
       # server_id => %{bytes_sent: X, bytes_received: Y, active_users: Z}
       server_stats: %{},
       # {server_id, user_config_id} => %{bytes_sent: X, bytes_received: Y}
       user_stats: %{}
     }}
  end

  @impl true
  def handle_cast(
        {:record_bandwidth, server_id, user_config_id, bytes_sent, bytes_received},
        state
      ) do
    # Update server stats
    server_stats =
      Map.update(
        state.server_stats,
        server_id,
        %{bytes_sent: bytes_sent, bytes_received: bytes_received, active_users: 1},
        fn existing ->
          %{
            bytes_sent: max(existing.bytes_sent, bytes_sent),
            bytes_received: max(existing.bytes_received, bytes_received),
            active_users: existing.active_users + 1
          }
        end
      )

    # Update user stats
    user_stats =
      Map.put(state.user_stats, {server_id, user_config_id}, %{
        bytes_sent: bytes_sent,
        bytes_received: bytes_received,
        last_updated: DateTime.utc_now()
      })

    {:noreply, %{state | server_stats: server_stats, user_stats: user_stats}}
  end

  @impl true
  def handle_call(:get_aggregate_stats, _from, state) do
    total_sent = state.server_stats |> Map.values() |> Enum.map(& &1.bytes_sent) |> Enum.sum()

    total_received =
      state.server_stats |> Map.values() |> Enum.map(& &1.bytes_received) |> Enum.sum()

    active_connections =
      state.server_stats |> Map.values() |> Enum.map(& &1.active_users) |> Enum.sum()

    stats = %{
      total_bandwidth: total_sent + total_received,
      total_sent: total_sent,
      total_received: total_received,
      active_connections: active_connections,
      server_count: map_size(state.server_stats),
      server_stats: state.server_stats
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_server_stats, server_id}, _from, state) do
    stats =
      Map.get(state.server_stats, server_id, %{bytes_sent: 0, bytes_received: 0, active_users: 0})

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_to_db, state) do
    flush_stats_to_db(state.user_stats)
    schedule_flush()
    {:noreply, state}
  end

  ## Private Functions

  defp schedule_flush do
    Process.send_after(self(), :flush_to_db, @flush_interval)
  end

  defp flush_stats_to_db(user_stats) do
    # Batch update user configs with latest bandwidth stats
    Enum.each(user_stats, fn {{_server_id, user_config_id}, stats} ->
      try do
        config = VPN.get_user_config!(user_config_id)

        VPN.update_user_config(config, %{
          bytes_sent: stats.bytes_sent,
          bytes_received: stats.bytes_received
        })
      rescue
        # Config might have been deleted
        _ -> :ok
      end
    end)

    Logger.debug("Flushed VPN stats to database (#{map_size(user_stats)} configs)")
  end
end
