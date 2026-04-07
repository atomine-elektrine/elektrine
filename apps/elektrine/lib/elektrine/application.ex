defmodule Elektrine.Application do
  @moduledoc false

  use Application

  alias Elektrine.Platform.ModuleProviders

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
      Elektrine.MailAuth.RateLimiter
    ] ++ ModuleProviders.core_children()
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
      ] ++ ModuleProviders.web_children() ++ [ElektrineWeb.Endpoint]
    else
      []
    end
  end

  defp mail_children do
    if component_enabled?(:mail) do
      ModuleProviders.mail_children()
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
end
