defmodule Elektrine.DNS.Authority do
  @moduledoc """
  Initial supervisor-facing process for Elektrine's authoritative DNS runtime.

  This intentionally starts as a lightweight Elixir-owned process so the zone
  model, query pipeline, and release wiring can land before UDP/TCP serving is
  implemented.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info(
      "Elektrine DNS authority starting on udp=#{Elektrine.DNS.udp_port()} tcp=#{Elektrine.DNS.tcp_port()} opts=#{inspect(opts)}"
    )

    {:ok, %{udp_port: Elektrine.DNS.udp_port(), tcp_port: Elektrine.DNS.tcp_port()}}
  end
end
