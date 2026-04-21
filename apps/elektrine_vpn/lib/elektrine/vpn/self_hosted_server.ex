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
    case Elektrine.VPN.ensure_self_host_servers() do
      {:ok, []} ->
        :ok

      {:ok, servers} ->
        Enum.each(servers, fn server ->
          Logger.info(
            "Self-hosted #{Elektrine.VPN.server_protocol_label(server)} server ready: #{server.name} (ID: #{server.id})"
          )
        end)

      {:error, changeset} ->
        Logger.error("Failed to bootstrap self-hosted VPN server: #{inspect(changeset.errors)}")
    end

    {:noreply, state}
  end
end
