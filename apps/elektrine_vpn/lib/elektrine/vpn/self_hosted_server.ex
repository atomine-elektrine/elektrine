defmodule Elektrine.VPN.SelfHostedServer do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :ensure_server)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ensure_server, state) do
    case Elektrine.VPN.ensure_self_host_server() do
      {:ok, nil} ->
        :ok

      {:ok, server} ->
        Logger.info("Self-hosted WireGuard server ready: #{server.name} (ID: #{server.id})")

      {:error, changeset} ->
        Logger.error(
          "Failed to bootstrap self-hosted WireGuard server: #{inspect(changeset.errors)}"
        )
    end

    {:noreply, state}
  end
end
