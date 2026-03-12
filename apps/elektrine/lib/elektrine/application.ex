defmodule Elektrine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    add_sentry_handler()

    children =
      core_children() ++
        jobs_children() ++
        web_children() ++
        mail_children()

    opts = [strategy: :one_for_one, name: Elektrine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    if Code.ensure_loaded?(ElektrineWeb.Endpoint) do
      ElektrineWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end

  defp add_sentry_handler do
    case :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
           config: %{metadata: [:file, :line]}
         }) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      {:error, {:already_exists, _}} -> :ok
      _ -> :ok
    end
  end

  defp core_children do
    [
      Elektrine.Repo,
      {DNSCluster, query: Application.get_env(:elektrine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Elektrine.PubSub},
      {Finch, name: Elektrine.Finch},
      {Registry, keys: :unique, name: Elektrine.Messaging.FederationSessionRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Elektrine.Messaging.FederationSessionSupervisor},
      Elektrine.AppCache,
      Elektrine.Encryption.KeyCache,
      Elektrine.Messaging.RateLimiter,
      Elektrine.Auth.RateLimiter,
      Elektrine.API.RateLimiter,
      Elektrine.Search.RateLimiter,
      Elektrine.HTTP.Backoff,
      Elektrine.Email.Cache,
      Elektrine.MailAuth.RateLimiter,
      Elektrine.Email.RateLimiter
    ]
  end

  defp jobs_children do
    if component_enabled?(:jobs) do
      [
        {Oban, Application.fetch_env!(:elektrine, Oban)},
        Elektrine.Scheduler
      ]
    else
      []
    end
  end

  defp web_children do
    if component_enabled?(:web) do
      [
        ElektrineWeb.Telemetry,
        Elektrine.Webhook.RateLimiter,
        Elektrine.Timeline.RateLimiter,
        Elektrine.DAV.RateLimiter,
        Elektrine.SecurityAlerts.Cache,
        Elektrine.VPN.PeerCache,
        Elektrine.VPN.HealthMonitor,
        Elektrine.VPN.StatsAggregator,
        ElektrineWeb.Presence,
        Elektrine.ActivityPub.InboxRateLimiter,
        Elektrine.ActivityPub.DomainThrottler,
        Elektrine.ActivityPub.InboxQueue,
        Elektrine.ActivityPub.Nodeinfo,
        Elektrine.ActivityPub.CommunityFetcher,
        ElektrineWeb.Endpoint
      ]
    else
      []
    end
  end

  defp mail_children do
    if component_enabled?(:mail) do
      [
        Elektrine.POP3.Supervisor,
        Elektrine.IMAP.Supervisor,
        Elektrine.SMTP.Supervisor
      ]
    else
      []
    end
  end

  defp component_enabled?(component) do
    :elektrine
    |> Application.get_env(:runtime_components, [])
    |> Keyword.get(component, true)
  end
end
