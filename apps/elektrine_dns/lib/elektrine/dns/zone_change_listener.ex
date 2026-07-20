defmodule Elektrine.DNS.ZoneChangeListener do
  @moduledoc """
  Cross-node zone-cache invalidation over Postgres LISTEN/NOTIFY.

  The public authoritative nameserver (`elektrine_dns`) runs in a different
  OS container — and therefore a different, unclustered BEAM node — from the
  web app (`elektrine_app`) where DNS records are edited. A record write on
  the app node refreshes only that node's `ZoneCache`; without this listener
  the nameserver would not serve the change until its periodic refresh timer
  fired (up to `zone_cache_refresh_interval_ms` later), which is exactly the
  window the Atomine create-record-then-verify proof flow lands in.

  On every record/zone write, `Elektrine.DNS` emits `pg_notify` on the
  `elektrine_dns_zone_changed` channel. This GenServer listens on that
  channel through a dedicated `Postgrex.Notifications` connection (the
  shared database is the
  only channel the two nodes have in common) and refreshes the local
  `ZoneCache`, debounced so a burst of writes collapses into one reload.
  """

  use GenServer

  require Logger

  alias Elektrine.DNS.ZoneCache

  @channel "elektrine_dns_zone_changed"
  @debounce_ms 250

  def channel, do: @channel

  @doc "Emit a zone-changed notification. Safe to call from any node."
  def notify(repo \\ Elektrine.Repo) do
    repo.query("SELECT pg_notify($1, $2)", [@channel, ""])
    :ok
  rescue
    error ->
      Logger.warning("DNS zone-change notify failed: #{Exception.message(error)}")
      :error
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, Elektrine.Repo)

    case start_notifications(repo) do
      {:ok, pid} ->
        ref = Postgrex.Notifications.listen!(pid, @channel)
        {:ok, %{notifications: pid, ref: ref, timer: nil}}

      {:error, reason} ->
        # Do not take down the authority tree if the listener can't connect;
        # the periodic ZoneCache refresh still covers correctness, just
        # slower. Retry shortly.
        Logger.warning("DNS zone-change listener could not start: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, 5_000)
        {:ok, %{notifications: nil, ref: nil, timer: nil}}
    end
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @channel, _payload}, state) do
    {:noreply, schedule_refresh(state)}
  end

  def handle_info(:refresh, state) do
    ZoneCache.refresh_async()
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:reconnect, %{notifications: nil} = state) do
    repo = Elektrine.Repo

    case start_notifications(repo) do
      {:ok, pid} ->
        ref = Postgrex.Notifications.listen!(pid, @channel)
        # A write may have happened while we were disconnected.
        ZoneCache.refresh_async()
        {:noreply, %{state | notifications: pid, ref: ref}}

      {:error, _reason} ->
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{notifications: pid} = state) do
    Process.send_after(self(), :reconnect, 5_000)
    {:noreply, %{state | notifications: nil, ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_refresh(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :refresh, @debounce_ms)}
  end

  # A refresh is already pending; the debounce window will cover this write too.
  defp schedule_refresh(state), do: state

  # Ecto's repo.config/0 carries pool/telemetry/adapter keys that a raw
  # Postgrex.Notifications connection has no use for; keep only connection
  # parameters (which also accepts a :url shorthand).
  @connection_keys ~w(url hostname port username password database
    socket socket_dir ssl ssl_opts parameters connect_timeout
    handshake_timeout show_sensitive_data_on_connection_error)a

  defp start_notifications(repo) do
    config = repo.config() |> Keyword.take(@connection_keys)

    case Postgrex.Notifications.start_link(config) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
