defmodule Elektrine.VPN.HealthMonitor do
  @moduledoc """
  GenServer that monitors VPN server health.
  Tracks heartbeats and automatically marks servers offline if they stop responding.
  """
  use GenServer
  require Logger

  alias Elektrine.VPN

  @heartbeat_timeout :timer.minutes(5)
  @check_interval :timer.minutes(1)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a heartbeat from a server.
  """
  def heartbeat(server_id) do
    GenServer.cast(__MODULE__, {:heartbeat, server_id, DateTime.utc_now()})
  end

  @doc """
  Get last heartbeat time for a server.
  """
  def last_heartbeat(server_id) do
    GenServer.call(__MODULE__, {:get_heartbeat, server_id})
  end

  @doc """
  Get health status for all servers.
  """
  def health_status do
    GenServer.call(__MODULE__, :health_status)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic health checks
    schedule_health_check()

    Logger.info("VPN HealthMonitor started")
    {:ok, %{heartbeats: %{}}}
  end

  @impl true
  def handle_cast({:heartbeat, server_id, timestamp}, state) do
    new_heartbeats = Map.put(state.heartbeats, server_id, timestamp)
    {:noreply, %{state | heartbeats: new_heartbeats}}
  end

  @impl true
  def handle_call({:get_heartbeat, server_id}, _from, state) do
    {:reply, Map.get(state.heartbeats, server_id), state}
  end

  @impl true
  def handle_call(:health_status, _from, state) do
    now = DateTime.utc_now()

    status =
      Enum.map(state.heartbeats, fn {server_id, last_heartbeat} ->
        seconds_since = DateTime.diff(now, last_heartbeat)
        is_healthy = seconds_since < div(@heartbeat_timeout, 1000)

        %{
          server_id: server_id,
          last_heartbeat: last_heartbeat,
          seconds_since: seconds_since,
          healthy: is_healthy
        }
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_info(:check_health, state) do
    check_server_health(state.heartbeats)
    schedule_health_check()
    {:noreply, state}
  end

  ## Private Functions

  defp schedule_health_check do
    Process.send_after(self(), :check_health, @check_interval)
  end

  defp check_server_health(heartbeats) do
    now = DateTime.utc_now()

    Enum.each(heartbeats, fn {server_id, last_heartbeat} ->
      seconds_since = DateTime.diff(now, last_heartbeat)

      if seconds_since > div(@heartbeat_timeout, 1000) do
        # Server hasn't sent heartbeat in 5+ minutes
        Logger.warning(
          "VPN Server #{server_id} appears offline (no heartbeat for #{seconds_since}s)"
        )

        # Auto-mark as offline
        case VPN.get_server!(server_id) do
          %{status: "active"} = server ->
            VPN.update_server(server, %{status: "offline"})
            Logger.warning("Marked VPN Server #{server_id} as offline")

          _ ->
            :ok
        end
      end
    end)
  end
end
