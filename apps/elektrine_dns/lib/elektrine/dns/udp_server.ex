defmodule Elektrine.DNS.UDPServer do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, socket} =
      :gen_udp.open(Elektrine.DNS.udp_port(), [
        :binary,
        active: 100,
        reuseaddr: true,
        ip: {0, 0, 0, 0}
      ])

    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_info({:udp, socket, host, port, packet}, state) do
    case Elektrine.DNS.RequestGuard.begin_request(host, :udp) do
      {:ok, :udp} ->
        Task.Supervisor.start_child(Elektrine.DNS.TaskSupervisor, fn ->
          try do
            response = Elektrine.DNS.Query.answer(packet, client_ip: host, transport: :udp)
            :gen_udp.send(socket, host, port, response)
          after
            Elektrine.DNS.RequestGuard.finish_request(:udp)
          end
        end)

      {:error, _reason} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:udp_passive, socket}, state) do
    :inet.setopts(socket, active: 100)
    {:noreply, state}
  end
end
