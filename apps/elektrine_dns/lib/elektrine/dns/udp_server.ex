defmodule Elektrine.DNS.UDPServer do
  @moduledoc false

  use GenServer

  require Logger

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

    case open(family) do
      {:ok, socket} ->
        {:ok, %{socket: socket}}

      {:error, reason} when family == :inet6 ->
        Logger.warning("DNS UDP IPv6 listener unavailable: #{inspect(reason)}")
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp open(family) do
    :gen_udp.open(
      Elektrine.DNS.udp_port(),
      [
        :binary,
        family,
        active: 100,
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
  def handle_info({:udp, socket, host, port, packet}, state) do
    case Elektrine.DNS.RequestGuard.begin_request(host, :udp) do
      {:ok, :udp} ->
        case Task.Supervisor.start_child(Elektrine.DNS.TaskSupervisor, fn ->
               try do
                 result = Elektrine.DNS.Query.resolve(packet, client_ip: host, transport: :udp)
                 Elektrine.DNS.track_query(result, "udp")
                 :gen_udp.send(socket, host, port, result.response)
               after
                 Elektrine.DNS.RequestGuard.finish_request(:udp)
               end
             end) do
          {:ok, _pid} -> :ok
          {:error, _reason} -> Elektrine.DNS.RequestGuard.finish_request(:udp)
        end

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
