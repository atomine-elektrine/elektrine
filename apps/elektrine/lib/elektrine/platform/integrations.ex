defmodule Elektrine.Platform.Integrations do
  @moduledoc false

  alias Elektrine.Platform.ModuleProviders

  def send_vpn_quota_notification(:suspended, user, user_config) do
    ModuleProviders.send_vpn_quota_notification(:suspended, [user, user_config])
  end

  def send_vpn_quota_notification(:warning, user, user_config, threshold) do
    ModuleProviders.send_vpn_quota_notification(:warning, [user, user_config, threshold])
  end
end
