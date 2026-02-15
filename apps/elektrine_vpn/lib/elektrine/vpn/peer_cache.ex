defmodule Elektrine.VPN.PeerCache do
  @moduledoc """
  GenServer that caches peer configurations for VPN servers.
  Reduces database load by caching API responses for peer lists.
  Cache is invalidated when user configs are created/updated/deleted.
  """
  use GenServer
  require Logger

  @cache_name :vpn_peer_cache
  @cache_ttl :timer.minutes(5)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached peer configurations for a server.
  Returns nil if not cached, caller should fetch from DB and cache.
  """
  def get(server_id) do
    Cachex.get(@cache_name, {:peers, server_id})
    |> case do
      {:ok, nil} -> nil
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc """
  Cache peer configurations for a server.
  """
  def put(server_id, peers) do
    Cachex.put(@cache_name, {:peers, server_id}, peers, ttl: @cache_ttl)
  end

  @doc """
  Invalidate cache for a specific server.
  Called when user configs change.
  """
  def invalidate(server_id) do
    Cachex.del(@cache_name, {:peers, server_id})
    Logger.debug("VPN peer cache invalidated for server #{server_id}")
  end

  @doc """
  Clear all peer caches.
  """
  def clear_all do
    Cachex.clear(@cache_name)
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    {:ok, stats} = Cachex.stats(@cache_name)
    stats
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Start Cachex cache
    {:ok, _pid} = Cachex.start_link(@cache_name, [])

    Logger.info("VPN PeerCache started")
    {:ok, %{}}
  end
end
