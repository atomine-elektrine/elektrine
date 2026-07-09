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
  def init(_opts), do: {:ok, %{ports: %{}}}

  @impl true
  def handle_call({:apply_snapshot, snapshot}, _from, state) do
    changed = ShadowsocksAdapter.config_changed?(snapshot)
    :ok = ShadowsocksAdapter.write_config(snapshot)

    state =
      if changed or map_size(state.ports) == 0 do
        restart_servers(snapshot, state)
      else
        state
      end

    {:reply, :ok, state}
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

    case ShadowsocksAdapter.start_servers(snapshot) do
      {:ok, ports} ->
        %{state | ports: ports}

      {:error, reason} ->
        Logger.error("Self-hosted Shadowsocks failed to start: #{inspect(reason)}")
        %{state | ports: %{}}
    end
  end
end
