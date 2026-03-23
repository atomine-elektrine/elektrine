defmodule Elektrine.DNS.ZoneCache do
  @moduledoc """
  ETS-backed cache for authoritative zone data.
  """

  use GenServer
  import Ecto.Query, only: [preload: 2]

  alias Elektrine.DNS.Zone
  alias Elektrine.Repo

  @table __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def lookup(domain) when is_binary(domain) do
    case :ets.lookup(@table, String.downcase(domain)) do
      [{_domain, zone}] -> {:ok, zone}
      [] -> :error
    end
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, refresh_cache(%{})}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {:reply, :ok, refresh_cache(state)}
  end

  defp refresh_cache(state) do
    :ets.delete_all_objects(@table)

    try do
      Zone
      |> preload(:records)
      |> Repo.all()
      |> Enum.each(fn zone ->
        :ets.insert(@table, {String.downcase(zone.domain), zone})
      end)
    rescue
      Postgrex.Error -> :ok
    end

    state
  end
end
