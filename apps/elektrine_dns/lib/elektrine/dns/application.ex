defmodule Elektrine.DNS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Elektrine.DNS.ZoneCache,
        Elektrine.DNS.RecursiveCache,
        Elektrine.DNS.RequestGuard,
        {Task.Supervisor, name: Elektrine.DNS.TaskSupervisor}
      ] ++ authority_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Elektrine.DNS.Supervisor)
  end

  defp authority_children do
    if Elektrine.DNS.authority_enabled?() do
      [Elektrine.DNS.Authority, Elektrine.DNS.UDPServer, Elektrine.DNS.TCPServer]
    else
      []
    end
  end
end
