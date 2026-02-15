defmodule Elektrine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    children = [
      ElektrineWeb.Telemetry,
      Elektrine.Repo,
      {DNSCluster, query: Application.get_env(:elektrine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Elektrine.PubSub},
      {Finch, name: Elektrine.Finch},
      Elektrine.Scheduler,
      {Oban, Application.fetch_env!(:elektrine, Oban)},
      Elektrine.Email.Cache,
      Elektrine.AppCache,
      Elektrine.Encryption.KeyCache,
      Elektrine.Messaging.RateLimiter,
      Elektrine.Auth.RateLimiter,
      Elektrine.MailAuth.RateLimiter,
      Elektrine.Email.RateLimiter,
      Elektrine.Webhook.RateLimiter,
      Elektrine.API.RateLimiter,
      Elektrine.DAV.RateLimiter,
      Elektrine.SecurityAlerts.Cache,
      Elektrine.VPN.PeerCache,
      Elektrine.VPN.HealthMonitor,
      Elektrine.VPN.StatsAggregator,
      ElektrineWeb.Presence,
      Elektrine.POP3.Supervisor,
      Elektrine.IMAP.Supervisor,
      Elektrine.SMTP.Supervisor,
      Elektrine.HTTP.Backoff,
      Elektrine.ActivityPub.InboxRateLimiter,
      Elektrine.ActivityPub.DomainThrottler,
      Elektrine.ActivityPub.InboxQueue,
      Elektrine.ActivityPub.Nodeinfo,
      Elektrine.CustomDomains.CertificateCache,
      Elektrine.CustomDomains.AcmeChallengeStore,
      Elektrine.CustomDomains.CertProvisioner,
      ElektrineWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Elektrine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElektrineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
