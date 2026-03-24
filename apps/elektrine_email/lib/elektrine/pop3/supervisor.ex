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
    tls_port = pop3s_port()
    tls_enabled = pop3s_enabled?()
    tls_opts = pop3_tls_opts()

    require Logger

    Logger.info(
      "Startup: pop3 supervisor configured (enabled=#{enabled}, port=#{port}, tls_enabled=#{tls_enabled}, tls_port=#{tls_port})"
    )

    children =
      [Elektrine.POP3.RateLimiter] ++
        if(enabled,
          do: [
            Supervisor.child_spec(
              {Elektrine.POP3.Server, [name: Elektrine.POP3.Server, port: port]},
              id: Elektrine.POP3.Server
            )
          ],
          else: []
        ) ++
        if(tls_enabled,
          do: [
            Supervisor.child_spec(
              {Elektrine.POP3.Server,
               [
                 name: Elektrine.POP3.TLSServer,
                 port: tls_port,
                 transport: :ssl,
                 tls_opts: tls_opts
               ]},
              id: Elektrine.POP3.TLSServer
            )
          ],
          else: []
        )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pop3_enabled? do
    Application.get_env(:elektrine, :pop3_enabled, true)
  end

  defp pop3_port do
    Application.get_env(:elektrine, :pop3_port, 2110)
  end

  defp pop3s_enabled? do
    Application.get_env(:elektrine, :pop3s_enabled, false)
  end

  defp pop3s_port do
    Application.get_env(:elektrine, :pop3s_port, 995)
  end

  defp pop3_tls_opts do
    Application.get_env(:elektrine, :mail_tls_opts, [])
  end
end
