defmodule Elektrine.CaddyTLSDomainCache do
  @moduledoc """
  Owns the ETS table used by the Caddy on-demand TLS allowlist cache.
  """

  use GenServer

  @table_name :caddy_tls_domain_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    {:ok, %{}}
  end
end
