defmodule Elektrine.VPN.SelfHostedShadowsocksServer do
  @moduledoc false

  use GenServer

  alias Elektrine.VPN.ShadowsocksAdapter

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def apply_snapshot(snapshot) do
    GenServer.call(__MODULE__, {:apply_snapshot, snapshot}, 15_000)
  end

  @impl true
  def init(_opts) do
    state = %{ports: %{}, manager: nil, manager_path: nil, port_clients: %{}, server_id: nil}
    {:ok, open_manager_socket(state)}
  end

  @impl true
  def handle_call({:apply_snapshot, snapshot}, _from, state) do
    changed = ShadowsocksAdapter.config_changed?(snapshot)
    :ok = ShadowsocksAdapter.write_config(snapshot)

    state = %{
      state
      | port_clients: build_port_clients(snapshot),
        server_id: get_in(snapshot, [:server, :id]) || state.server_id
    }

    state =
      if changed or map_size(state.ports) == 0 do
        restart_servers(snapshot, state)
      else
        state
      end

    {:reply, :ok, state}
  end

  # Per-port cumulative byte totals pushed by ss-server via --manager-address.
  @impl true
  def handle_info({:udp, _socket, _addr, _port, data}, state) do
    case ShadowsocksAdapter.parse_manager_stat(data) do
      {:ok, port_totals} when map_size(port_totals) > 0 -> report_stats(port_totals, state)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) do
    message = String.trim(data)

    if message != "" do
      Logger.info("Self-hosted Shadowsocks: #{message}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) do
    case Enum.find(state.ports, fn {_server_port, os_port} -> os_port == port end) do
      {server_port, _os_port} ->
        Logger.error("Self-hosted Shadowsocks port #{server_port} exited with status #{status}")
        {:noreply, %{state | ports: Map.delete(state.ports, server_port)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp restart_servers(snapshot, state) do
    ShadowsocksAdapter.close_ports(Map.values(state.ports))

    opts = if state.manager, do: [manager_socket: state.manager_path], else: []

    case ShadowsocksAdapter.start_servers(snapshot, opts) do
      {:ok, ports} ->
        %{state | ports: ports}

      {:error, reason} ->
        Logger.error("Self-hosted Shadowsocks failed to start: #{inspect(reason)}")
        %{state | ports: %{}}
    end
  end

  defp build_port_clients(snapshot) do
    snapshot.clients
    |> Enum.reject(&is_nil(&1.port))
    |> Map.new(fn client -> {client.port, client.client_id} end)
  end

  defp report_stats(port_totals, %{server_id: server_id, port_clients: port_clients})
       when not is_nil(server_id) do
    case ShadowsocksAdapter.stats_entries(port_totals, port_clients) do
      [] ->
        :ok

      entries ->
        # Offload the DB work so stat datagrams never block the GenServer.
        Elektrine.Async.start(fn -> Elektrine.VPN.report_peer_stats(server_id, entries) end)
    end
  end

  defp report_stats(_port_totals, _state), do: :ok

  # Best-effort: a missing manager socket disables quota accounting but must
  # never stop the tunnel, so failures degrade to running without stats.
  defp open_manager_socket(state) do
    path = ShadowsocksAdapter.manager_socket_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         _ <- File.rm(path),
         {:ok, socket} <-
           :gen_udp.open(0, [:binary, {:ifaddr, {:local, path}}, {:active, true}]) do
      Logger.info("Self-hosted Shadowsocks manager socket listening at #{path}")
      %{state | manager: socket, manager_path: path}
    else
      error ->
        Logger.warning(
          "Self-hosted Shadowsocks manager socket unavailable (#{inspect(error)}); " <>
            "quota accounting disabled"
        )

        %{state | manager: nil, manager_path: nil}
    end
  end
end
