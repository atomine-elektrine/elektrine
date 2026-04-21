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
  def init(_opts), do: {:ok, %{port: nil}}

  @impl true
  def handle_call({:apply_snapshot, snapshot}, _from, state) do
    changed = ShadowsocksAdapter.config_changed?(snapshot)
    :ok = ShadowsocksAdapter.write_config(snapshot)

    state =
      if changed or is_nil(state.port) do
        restart_server(state)
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
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Self-hosted Shadowsocks exited with status #{status}")
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp restart_server(state) do
    if state.port, do: Port.close(state.port)
    %{state | port: ShadowsocksAdapter.start_server()}
  end
end
