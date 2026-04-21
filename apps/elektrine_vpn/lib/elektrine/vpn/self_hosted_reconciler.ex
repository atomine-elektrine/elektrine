defmodule Elektrine.VPN.SelfHostedReconciler do
  @moduledoc false

  use GenServer

  alias Elektrine.PubSubTopics
  alias Elektrine.VPN
  alias Elektrine.VPN.SelfHostedShadowsocksServer
  alias Elektrine.VPN.WireGuardAdapter

  require Logger

  @default_interval_seconds 60
  @default_active_window_seconds 180

  def reconcile_now do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      PubSubTopics.vpn_self_hosted_reconcile(),
      :reconcile_now
    )

    :ok
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Elektrine.PubSub, PubSubTopics.vpn_self_hosted_reconcile())
    send(self(), :reconcile)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile_once()
    schedule_reconcile()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile_now, state) do
    reconcile_once()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reconcile_now, state) do
    reconcile_once()
    {:noreply, state}
  end

  defp reconcile_once do
    case VPN.ensure_self_host_servers() do
      {:ok, []} ->
        :ok

      {:ok, servers} ->
        Enum.each(servers, fn server ->
          case VPN.server_protocol(server) do
            "shadowsocks" -> reconcile_shadowsocks(server)
            _ -> reconcile_wireguard(server)
          end
        end)

      {:error, changeset} ->
        Logger.error("Failed to prepare self-hosted VPN servers: #{inspect(changeset.errors)}")
    end
  end

  defp reconcile_peers(interface, current_peers, snapshot) do
    desired_keys = snapshot.peers |> Enum.map(& &1.public_key) |> MapSet.new()

    remove_keys =
      snapshot.remove_peers
      |> Enum.map(& &1.public_key)
      |> Enum.concat(MapSet.to_list(MapSet.difference(current_peers, desired_keys)))
      |> Enum.uniq()

    Enum.each(remove_keys, &ignore_missing_peer(WireGuardAdapter.remove_peer(interface, &1)))
    Enum.each(snapshot.peers, &sync_peer(interface, &1))
    :ok
  end

  defp reconcile_wireguard(server) do
    interface = System.get_env("VPN_SELFHOST_WG_INTERFACE") || "wg0"

    active_window =
      env_integer("VPN_SELFHOST_ACTIVE_WINDOW_SECONDS", @default_active_window_seconds)

    with {:ok, current_peers} <- WireGuardAdapter.current_peer_keys(interface),
         snapshot <- VPN.peer_sync_snapshot(server.id),
         :ok <- reconcile_peers(interface, current_peers, snapshot),
         {:ok, stats} <- WireGuardAdapter.peer_stats(interface) do
      VPN.report_peer_stats(server.id, Enum.map(stats, &stringify_peer_stats/1))
      VPN.report_server_heartbeat(server.id, active_users(stats, active_window), "active")
    else
      {:error, reason} ->
        Logger.error("Self-hosted WireGuard reconcile failed: #{inspect(reason)}")
        VPN.report_server_heartbeat(server.id, 0, "offline")
    end
  end

  defp reconcile_shadowsocks(server) do
    snapshot = VPN.peer_sync_snapshot(server.id)

    case SelfHostedShadowsocksServer.apply_snapshot(snapshot) do
      :ok ->
        VPN.report_server_heartbeat(server.id, length(snapshot.clients), "active")

      {:error, reason} ->
        Logger.error("Self-hosted Shadowsocks reconcile failed: #{inspect(reason)}")
        VPN.report_server_heartbeat(server.id, 0, "offline")
    end
  rescue
    error ->
      Logger.error("Self-hosted Shadowsocks reconcile failed: #{inspect(error)}")
      VPN.report_server_heartbeat(server.id, 0, "offline")
  end

  defp sync_peer(interface, peer) do
    case WireGuardAdapter.sync_peer(interface, peer) do
      {:ok, _output} -> :ok
      {:error, reason} -> raise "wg sync failed for #{peer.public_key}: #{inspect(reason)}"
    end
  end

  defp ignore_missing_peer({:ok, _output}), do: :ok
  defp ignore_missing_peer({:error, _reason}), do: :ok

  defp stringify_peer_stats(peer) do
    peer
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp active_users(stats, active_window_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -active_window_seconds, :second)

    Enum.count(stats, fn peer ->
      case peer.last_handshake do
        nil -> false
        value -> DateTime.compare(DateTime.from_iso8601(value) |> elem(1), cutoff) in [:gt, :eq]
      end
    end)
  end

  defp schedule_reconcile do
    Process.send_after(
      self(),
      :reconcile,
      env_integer("VPN_SELFHOST_RECONCILE_INTERVAL_SECONDS", @default_interval_seconds) * 1000
    )
  end

  defp env_integer(key, default) do
    case System.get_env(key) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> default
        end
    end
  end
end
