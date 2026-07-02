defmodule Elektrine.Push.WebPushClient do
  @moduledoc """
  Default Web Push delivery adapter.

  Production can replace this with a configured VAPID sender through
  `config :elektrine, :web_push_client, MyApp.WebPushClient`.
  """

  require Logger

  def deliver(subscription, _payload, _opts \\ []) do
    Logger.debug("Web Push client not configured; skipping subscription #{subscription.id}")
    {:ok, :not_configured}
  end
end
