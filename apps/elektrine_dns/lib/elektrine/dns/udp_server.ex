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
        active: true,
        reuseaddr: true,
        ip: {0, 0, 0, 0}
      ])

    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_info({:udp, socket, host, port, packet}, state) do
    Task.Supervisor.start_child(Elektrine.DNS.TaskSupervisor, fn ->
      response = Elektrine.DNS.Query.answer(packet, client_ip: host)
      :gen_udp.send(socket, host, port, response)
    end)

    {:noreply, state}
  end
end
