defmodule Elektrine.IMAP.Supervisor do
  @moduledoc """
  Supervisor for the IMAP server and related processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    port = imap_port()
    enabled = imap_enabled?()

    require Logger
    Logger.info("IMAP Supervisor: enabled=#{enabled}, port=#{port}")

    children =
      if enabled do
        [
          # Rate limiter for auth attempts
          Elektrine.IMAP.RateLimiter,
          # IMAP Server
          {Elektrine.IMAP.Server, [port: port]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp imap_enabled? do
    # Re-enabled: Blocking at Fly.io level instead
    Application.get_env(:elektrine, :imap_enabled, true)
  end

  defp imap_port do
    # Use port 2143 by default (non-privileged port)
    # Can be overridden with IMAP_PORT env var
    Application.get_env(:elektrine, :imap_port, 2143)
  end
end
