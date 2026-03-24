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
    tls_port = imaps_port()
    tls_enabled = imaps_enabled?()
    tls_opts = imap_tls_opts()

    require Logger

    Logger.info(
      "Startup: imap supervisor configured (enabled=#{enabled}, port=#{port}, tls_enabled=#{tls_enabled}, tls_port=#{tls_port})"
    )

    children =
      [Elektrine.IMAP.RateLimiter] ++
        if(enabled,
          do: [
            Supervisor.child_spec(
              {Elektrine.IMAP.Server, [name: Elektrine.IMAP.Server, port: port]},
              id: Elektrine.IMAP.Server
            )
          ],
          else: []
        ) ++
        if(tls_enabled,
          do: [
            Supervisor.child_spec(
              {Elektrine.IMAP.Server,
               [
                 name: Elektrine.IMAP.TLSServer,
                 port: tls_port,
                 transport: :ssl,
                 tls_opts: tls_opts
               ]},
              id: Elektrine.IMAP.TLSServer
            )
          ],
          else: []
        )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp imap_enabled? do
    Application.get_env(:elektrine, :imap_enabled, true)
  end

  defp imap_port do
    Application.get_env(:elektrine, :imap_port, 2143)
  end

  defp imaps_enabled? do
    Application.get_env(:elektrine, :imaps_enabled, false)
  end

  defp imaps_port do
    Application.get_env(:elektrine, :imaps_port, 993)
  end

  defp imap_tls_opts do
    Application.get_env(:elektrine, :mail_tls_opts, [])
  end
end
