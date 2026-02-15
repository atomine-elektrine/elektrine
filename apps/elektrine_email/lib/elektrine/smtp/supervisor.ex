defmodule Elektrine.SMTP.Supervisor do
  @moduledoc """
  Supervisor for the SMTP server and related processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    port = smtp_port()
    enabled = smtp_enabled?()

    require Logger
    Logger.info("SMTP Supervisor: enabled=#{enabled}, port=#{port}")

    children =
      if enabled do
        [
          # Rate limiter for auth attempts
          Elektrine.SMTP.RateLimiter,
          # Rate limiter for sends per IP (anti-bot)
          Elektrine.SMTP.SendRateLimiter,
          # SMTP Server
          {Elektrine.SMTP.Server, [port: port]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp smtp_enabled? do
    # Re-enabled: Blocking at Fly.io level instead
    Application.get_env(:elektrine, :smtp_enabled, true)
  end

  defp smtp_port do
    # Use port 2587 by default (non-privileged port)
    # Can be overridden with SMTP_PORT env var
    Application.get_env(:elektrine, :smtp_port, 2587)
  end
end
