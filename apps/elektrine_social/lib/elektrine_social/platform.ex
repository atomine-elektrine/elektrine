defmodule ElektrineSocial.Platform do
  @moduledoc false
  @behaviour Elektrine.Platform.ModuleProvider

  def core_children, do: []

  def web_children do
    [
      Elektrine.Timeline.RateLimiter,
      Elektrine.ActivityPub.InboxRateLimiter,
      Elektrine.ActivityPub.DomainThrottler,
      Elektrine.ActivityPub.InboxQueue,
      Elektrine.ActivityPub.Nodeinfo
    ]
  end

  def mail_children, do: []

  def optional_delegate(_name), do: nil
end
