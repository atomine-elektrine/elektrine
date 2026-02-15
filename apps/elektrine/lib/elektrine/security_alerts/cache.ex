defmodule Elektrine.SecurityAlerts.Cache do
  @moduledoc """
  Cache for rate limiting security alerts.
  """

  @cache_name :security_alerts_cache

  def start_link(_opts) do
    Cachex.start_link(@cache_name,
      limit: 10_000,
      ttl: :timer.hours(1)
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end
end
