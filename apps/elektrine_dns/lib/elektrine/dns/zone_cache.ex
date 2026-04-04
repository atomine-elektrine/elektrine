defmodule Elektrine.DNS.ZoneCache do
  @moduledoc """
  ETS-backed cache for authoritative zone data.
  """

  use GenServer
  import Ecto.Query, only: [preload: 2]

  require Logger

  alias Elektrine.DNS.Zone
  alias Elektrine.Repo

  @table __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def lookup(domain) when is_binary(domain) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _table ->
        case :ets.lookup(@table, String.downcase(domain)) do
          [{_domain, zone}] -> {:ok, zone}
          [] -> :error
        end
    end
  end

  def refresh(opts \\ []) do
    GenServer.call(__MODULE__, {:refresh, opts})
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])

    state = %{
      refresh_interval_ms:
        Keyword.get(opts, :refresh_interval_ms, Elektrine.DNS.zone_cache_refresh_interval_ms())
    }

    schedule_refresh(state.refresh_interval_ms)

    {:ok, refresh_cache(state)}
  end

  @impl true
  def handle_call({:refresh, opts}, _from, state) do
    {:reply, :ok, refresh_cache(state, opts)}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, refresh_cache(state)}
  end

  defp refresh_cache(state, opts \\ []) do
    repo_opts = Keyword.take(opts, [:caller])

    case load_zones(repo_opts) do
      {:ok, zones} ->
        :ets.delete_all_objects(@table)

        Enum.each(zones, fn zone ->
          :ets.insert(@table, {String.downcase(zone.domain), zone})
        end)

      {:error, error} ->
        Logger.warning("DNS zone cache refresh failed: #{Exception.message(error)}")
    end

    state
  end

  defp load_zones(repo_opts) do
    {:ok,
     Zone
     |> preload(:records)
     |> Repo.all(repo_opts)}
  rescue
    error in [Postgrex.Error, DBConnection.OwnershipError] ->
      {:error, error}
  end

  defp schedule_refresh(refresh_interval_ms)
       when is_integer(refresh_interval_ms) and refresh_interval_ms > 0 do
    Process.send_after(self(), :refresh, refresh_interval_ms)
  end

  defp schedule_refresh(_refresh_interval_ms), do: :ok
end
