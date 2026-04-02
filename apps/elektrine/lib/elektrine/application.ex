defmodule Elektrine.Application do
  @moduledoc false

  use Application

  alias Elektrine.Platform.Modules

  @impl true
  def start(_type, _args) do
    add_sentry_handler()

    children =
      core_children() ++
        jobs_children() ++
        vpn_children() ++
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
      Elektrine.MailAuth.RateLimiter
    ]
    |> maybe_add_email_core_children()
  end

  defp maybe_add_email_core_children(children) do
    if Modules.compiled?(:email) do
      children ++ [Elektrine.Email.Cache, Elektrine.Email.RateLimiter]
    else
      children
    end
  end

  defp jobs_children do
    cond do
      component_enabled?(:jobs) ->
        [
          {Oban, Application.fetch_env!(:elektrine, Oban)}
        ]

      component_enabled?(:web) ->
        [
          {Oban, enqueue_only_oban_config()}
        ]

      true ->
        []
    end
  end

  defp web_children do
    if component_enabled?(:web) and web_runtime_available?() do
      [
        ElektrineWeb.Telemetry,
        Elektrine.Webhook.RateLimiter,
        Elektrine.DAV.RateLimiter,
        Elektrine.SecurityAlerts.Cache,
        ElektrineWeb.Presence
      ] ++ social_web_children() ++ [ElektrineWeb.Endpoint]
    else
      []
    end
  end

  defp mail_children do
    if component_enabled?(:mail) and Modules.compiled?(:email) and Modules.enabled?(:email) do
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

  defp web_runtime_available? do
    Code.ensure_loaded?(ElektrineWeb.Telemetry) and
      Code.ensure_loaded?(ElektrineWeb.Presence) and
      Code.ensure_loaded?(ElektrineWeb.Endpoint)
  end

  defp enqueue_only_oban_config do
    Application.fetch_env!(:elektrine, Oban)
    |> Keyword.merge(
      plugins: [],
      queues: [],
      stage_interval: :infinity
    )
  end

  defp social_web_children do
    if Modules.compiled?(:social) and Modules.enabled?(:social) do
      [
        Elektrine.Timeline.RateLimiter,
        Elektrine.ActivityPub.InboxRateLimiter,
        Elektrine.ActivityPub.DomainThrottler,
        Elektrine.ActivityPub.InboxQueue,
        Elektrine.ActivityPub.Nodeinfo
      ]
    else
      []
    end
  end

  defp vpn_children do
    if Modules.compiled?(:vpn) and Modules.enabled?(:vpn) do
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
    else
      []
    end
  end

  defp self_host_vpn_node? do
    case System.get_env("VPN_SELFHOST_NODE") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      _ -> false
    end
  end
end
