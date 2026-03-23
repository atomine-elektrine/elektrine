defmodule Elektrine.DNS.TCPServer do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, listen_socket} =
      :gen_tcp.listen(Elektrine.DNS.tcp_port(), [
        :binary,
        packet: 0,
        active: false,
        reuseaddr: true,
        ip: {0, 0, 0, 0}
      ])

    send(self(), :accept)
    {:ok, %{listen_socket: listen_socket}}
  end

  @impl true
  def handle_info(:accept, state) do
    {:ok, socket} = :gen_tcp.accept(state.listen_socket)
    Task.start(fn -> serve_client(socket) end)
    send(self(), :accept)
    {:noreply, state}
  end

  defp serve_client(socket) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 5_000),
         {:ok, packet} <- :gen_tcp.recv(socket, length, 5_000) do
      response = Elektrine.DNS.Query.answer(packet)
      :gen_tcp.send(socket, <<byte_size(response)::16, response::binary>>)
    end

    :gen_tcp.close(socket)
  end
end
