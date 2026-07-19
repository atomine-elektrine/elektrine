defmodule Elektrine.DNS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Elektrine.DNS.RecursiveCache,
        Elektrine.DNS.RequestGuard,
        Elektrine.DNS.QueryStatsBuffer,
        {Task.Supervisor, name: Elektrine.DNS.TaskSupervisor}
      ] ++ authority_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Elektrine.DNS.Supervisor)
  end

  defp authority_children do
    if Elektrine.DNS.authority_enabled?() do
      [
        Elektrine.DNS.ZoneCache,
        Elektrine.DNS.HealthMonitor,
        Elektrine.DNS.ProfileWildcardBootstrap,
        Elektrine.DNS.Authority,
        {Elektrine.DNS.UDPServer, name: Elektrine.DNS.UDPServer, family: :inet},
        {Elektrine.DNS.UDPServer, name: Elektrine.DNS.UDPServerV6, family: :inet6},
        {Elektrine.DNS.TCPServer, name: Elektrine.DNS.TCPServer, family: :inet},
        {Elektrine.DNS.TCPServer, name: Elektrine.DNS.TCPServerV6, family: :inet6}
      ]
    else
      []
    end
  end
end
