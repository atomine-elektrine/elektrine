defmodule Elektrine.POP3.Supervisor do
  @moduledoc """
  Supervisor for the POP3 server and related processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    port = pop3_port()
    enabled = pop3_enabled?()

    require Logger
    Logger.info("POP3 Supervisor: enabled=#{enabled}, port=#{port}")

    children =
      if enabled do
        [
          # Rate limiter for auth attempts
          Elektrine.POP3.RateLimiter,
          # POP3 Server
          {Elektrine.POP3.Server, [port: port]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pop3_enabled? do
    # Re-enabled: Blocking at Fly.io level instead
    Application.get_env(:elektrine, :pop3_enabled, true)
  end

  defp pop3_port do
    # Use port 2110 by default (non-privileged port)
    # Can be overridden with POP3_PORT env var
    Application.get_env(:elektrine, :pop3_port, 2110)
  end
end
