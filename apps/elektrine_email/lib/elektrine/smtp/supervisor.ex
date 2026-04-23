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
    tls_port = smtps_port()
    tls_enabled = smtps_enabled?()
    tls_opts = smtp_tls_opts()

    require Logger

    Logger.info(
      "Startup: smtp supervisor configured (enabled=#{enabled}, port=#{port}, tls_enabled=#{tls_enabled}, tls_port=#{tls_port})"
    )

    children =
      [Elektrine.SMTP.RateLimiter, Elektrine.SMTP.SendRateLimiter] ++
        if(enabled, do: [{Elektrine.SMTP.Server, [port: port, tls_opts: tls_opts]}], else: []) ++
        if(tls_enabled,
          do: [
            Supervisor.child_spec(
              {Elektrine.SMTP.Server,
               [
                 name: Elektrine.SMTP.TLSServer,
                 port: tls_port,
                 transport: :ssl,
                 tls_opts: tls_opts
               ]},
              id: Elektrine.SMTP.TLSServer
            )
          ],
          else: []
        )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp smtp_enabled? do
    Application.get_env(:elektrine, :smtp_enabled, true)
  end

  defp smtp_port do
    # Internal listener uses a non-privileged port; deploys can publish it as 587 externally.
    Application.get_env(:elektrine, :smtp_port, 2587)
  end

  defp smtps_enabled? do
    Application.get_env(:elektrine, :smtps_enabled, false)
  end

  defp smtps_port do
    Application.get_env(:elektrine, :smtps_port, 2465)
  end

  defp smtp_tls_opts do
    Application.get_env(:elektrine, :smtp_tls_opts, [])
  end
end
