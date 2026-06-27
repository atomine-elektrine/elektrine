defmodule Elektrine.DNS.ProfileWildcardBootstrap do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :ensure_profile_wildcards}}

  @impl true
  def handle_continue(:ensure_profile_wildcards, state) do
    results = Elektrine.DNS.ensure_profile_subdomain_wildcards()

    Enum.each(results, fn
      {_domain, :ok} ->
        :ok

      {domain, {:error, reason}} ->
        Logger.info("Profile DNS wildcard not installed for #{domain}: #{inspect(reason)}")
    end)

    {:noreply, state}
  rescue
    error ->
      Logger.warning("Profile DNS wildcard bootstrap failed: #{Exception.message(error)}")
      {:noreply, state}
  end
end
