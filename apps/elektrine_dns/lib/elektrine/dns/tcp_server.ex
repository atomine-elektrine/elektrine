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
        backlog: Elektrine.DNS.tcp_max_inflight(),
        reuseaddr: true,
        ip: {0, 0, 0, 0}
      ])

    send(self(), :accept)
    {:ok, %{listen_socket: listen_socket}}
  end

  @impl true
  def handle_info(:accept, state) do
    {:ok, socket} = :gen_tcp.accept(state.listen_socket)

    case :inet.peername(socket) do
      {:ok, {client_ip, _client_port}} ->
        case Elektrine.DNS.RequestGuard.begin_request(client_ip, :tcp) do
          {:ok, :tcp} ->
            Task.Supervisor.start_child(Elektrine.DNS.TaskSupervisor, fn ->
              serve_client(socket)
            end)

          {:error, _reason} ->
            :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end

    send(self(), :accept)
    {:noreply, state}
  end

  defp serve_client(socket) do
    {:ok, {client_ip, _client_port}} = :inet.peername(socket)

    try do
      with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 5_000),
           {:ok, packet} <- :gen_tcp.recv(socket, length, 5_000) do
        response = Elektrine.DNS.Query.answer(packet, client_ip: client_ip, transport: :tcp)
        :gen_tcp.send(socket, <<byte_size(response)::16, response::binary>>)
      end
    after
      Elektrine.DNS.RequestGuard.finish_request(:tcp)
      :gen_tcp.close(socket)
    end
  end
end
