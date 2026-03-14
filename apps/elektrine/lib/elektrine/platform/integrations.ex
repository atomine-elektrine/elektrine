defmodule Elektrine.Platform.Integrations do
  @moduledoc false

  alias Elektrine.Platform.Modules

  @email_sender_module :"Elixir.Elektrine.Email.Sender"

  def send_vpn_quota_notification(:suspended, user, user_config) do
    call_email_sender(:send_vpn_quota_suspended, [user, user_config])
  end

  def send_vpn_quota_notification(:warning, user, user_config, threshold) do
    call_email_sender(:send_vpn_quota_warning, [user, user_config, threshold])
  end

  defp call_email_sender(function, args) do
    if Modules.compiled?(:email) and Modules.enabled?(:email) and
         Code.ensure_loaded?(@email_sender_module) and
         function_exported?(@email_sender_module, function, length(args)) do
      apply(@email_sender_module, function, args)
    else
      :ok
    end
  end
end
