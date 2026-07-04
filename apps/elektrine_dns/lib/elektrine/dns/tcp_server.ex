defmodule Elektrine.DNS.TCPServer do
  @moduledoc false

  use GenServer

  require Logger

  alias Elektrine.DNS.RequestGuard

  @accept_timeout 1_000
  @accept_error_backoff_ms 200
  @recv_timeout 5_000
  @max_queries_per_connection 64

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl true
  def init(opts) do
    family = Keyword.get(opts, :family, :inet)

    case listen(family) do
      {:ok, listen_socket} ->
        send(self(), :accept)
        {:ok, %{listen_socket: listen_socket}}

      {:error, reason} when family == :inet6 ->
        Logger.warning("DNS TCP IPv6 listener unavailable: #{inspect(reason)}")
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp listen(family) do
    :gen_tcp.listen(
      Elektrine.DNS.tcp_port(),
      [
        :binary,
        family,
        packet: 2,
        active: false,
        backlog: Elektrine.DNS.tcp_max_inflight(),
        reuseaddr: true,
        ip: wildcard_address(family)
      ] ++ family_opts(family)
    )
  end

  defp wildcard_address(:inet), do: {0, 0, 0, 0}
  defp wildcard_address(:inet6), do: {0, 0, 0, 0, 0, 0, 0, 0}

  # v6only keeps the v6 wildcard bind from claiming the v4 port too.
  defp family_opts(:inet), do: []
  defp family_opts(:inet6), do: [{:ipv6_v6only, true}]

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_timeout) do
      {:ok, socket} ->
        hand_off(socket)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        # Transient accept failures (e.g. emfile) must not crash the acceptor.
        Logger.warning("DNS TCP accept failed: #{inspect(reason)}")
        Process.send_after(self(), :accept, @accept_error_backoff_ms)
        {:noreply, state}
    end
  end

  defp hand_off(socket) do
    case :inet.peername(socket) do
      {:ok, {client_ip, _client_port}} ->
        case RequestGuard.begin_request(client_ip, :tcp) do
          {:ok, :tcp} -> start_serving(socket, client_ip)
          {:error, _reason} -> :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp start_serving(socket, client_ip) do
    case Task.Supervisor.start_child(Elektrine.DNS.TaskSupervisor, fn ->
           serve_client(socket, client_ip)
         end) do
      {:ok, pid} ->
        # Tie the socket's lifetime to the serving task, not the acceptor.
        :gen_tcp.controlling_process(socket, pid)
        :ok

      {:error, _reason} ->
        RequestGuard.finish_request(:tcp)
        :gen_tcp.close(socket)
    end
  end

  defp serve_client(socket, client_ip) do
    serve_loop(socket, client_ip, @max_queries_per_connection)
  after
    RequestGuard.finish_request(:tcp)
    :gen_tcp.close(socket)
  end

  defp serve_loop(_socket, _client_ip, 0), do: :ok

  defp serve_loop(socket, client_ip, remaining) do
    with {:ok, packet} <- :gen_tcp.recv(socket, 0, @recv_timeout),
         :ok <- rate_check(client_ip, remaining) do
      result = Elektrine.DNS.Query.resolve(packet, client_ip: client_ip, transport: :tcp)
      Elektrine.DNS.track_query(result, "tcp")

      case :gen_tcp.send(socket, result.response) do
        :ok -> serve_loop(socket, client_ip, remaining - 1)
        {:error, _reason} -> :ok
      end
    else
      _ -> :ok
    end
  end

  # The connection's first query is covered by begin_request/2 at accept
  # time; every further query on the same connection consumes rate budget.
  defp rate_check(_client_ip, @max_queries_per_connection), do: :ok
  defp rate_check(client_ip, _remaining), do: RequestGuard.check_rate(client_ip, :tcp)
end
