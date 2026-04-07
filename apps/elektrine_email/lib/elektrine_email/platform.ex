defmodule ElektrineEmail.Platform do
  @moduledoc false
  @behaviour Elektrine.Platform.ModuleProvider

  def core_children do
    [Elektrine.Email.Cache, Elektrine.Email.RateLimiter]
  end

  def web_children, do: []

  def mail_children do
    [Elektrine.POP3.Supervisor, Elektrine.IMAP.Supervisor, Elektrine.SMTP.Supervisor]
  end

  def optional_delegate(:jmap_auth), do: ElektrineEmailWeb.Plugs.JMAPAuth
  def optional_delegate(_name), do: nil

  def send_vpn_quota_notification(:suspended, [user, user_config]) do
    Elektrine.Email.Sender.send_vpn_quota_suspended(user, user_config)
  end

  def send_vpn_quota_notification(:warning, [user, user_config, threshold]) do
    Elektrine.Email.Sender.send_vpn_quota_warning(user, user_config, threshold)
  end

  def send_vpn_quota_notification(_kind, _args), do: :ok
end
