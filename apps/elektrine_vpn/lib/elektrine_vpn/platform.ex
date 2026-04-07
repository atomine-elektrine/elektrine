defmodule ElektrineVPN.Platform do
  @moduledoc false
  @behaviour Elektrine.Platform.ModuleProvider

  def core_children do
    base_children = [
      Elektrine.VPN.PeerCache,
      Elektrine.VPN.HealthMonitor,
      Elektrine.VPN.StatsAggregator
    ]

    if self_host_vpn_node?() do
      base_children ++ [Elektrine.VPN.SelfHostedServer, Elektrine.VPN.SelfHostedReconciler]
    else
      base_children
    end
  end

  def web_children, do: []
  def mail_children, do: []
  def optional_delegate(_name), do: nil

  defp self_host_vpn_node? do
    case System.get_env("VPN_SELFHOST_NODE") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      _ -> false
    end
  end
end
