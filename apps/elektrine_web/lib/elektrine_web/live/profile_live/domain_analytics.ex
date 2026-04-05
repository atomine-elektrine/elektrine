defmodule ElektrineWeb.ProfileLive.DomainAnalytics do
  use ElektrineWeb, :live_view

  alias Elektrine.{Domains, Profiles}

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    domains = site_domains(user)
    active_host = select_active_host(domains, params["host"])

    {:ok,
     socket
     |> assign(:page_title, "Domain Analytics")
     |> assign(:domains, domains)
     |> assign_domain_analytics(user, active_host)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    domains = site_domains(user)
    active_host = select_active_host(domains, params["host"])

    {:noreply,
     socket
     |> assign(:domains, domains)
     |> assign_domain_analytics(user, active_host)}
  end

  defp assign_domain_analytics(socket, user, active_host) do
    domain_hosts = Enum.map(socket.assigns[:domains] || [], & &1.host)
    domain_breakdown = Profiles.get_site_domain_breakdown(user.id, domain_hosts)
    daily_views = Profiles.get_site_daily_view_counts(user.id, 30, active_host)

    socket
    |> assign(:active_host, active_host)
    |> assign(:stats, Profiles.get_site_view_stats(user.id, active_host))
    |> assign(
      :domain_breakdown,
      merge_domain_breakdown(socket.assigns[:domains] || [], domain_breakdown)
    )
    |> assign(:top_pages, Profiles.get_site_top_pages(user.id, active_host, 10))
    |> assign(:top_referrers, Profiles.get_site_top_referrers(user.id, active_host, 10))
    |> assign(:daily_views, daily_views)
    |> assign(:display_days, Enum.filter(daily_views, &(&1.count > 0)) |> Enum.reverse())
    |> assign(:max_daily_views, max_daily_views(daily_views))
  end

  defp site_domains(user) do
    built_in_host =
      user
      |> profile_host_url()
      |> parse_host()

    custom_hosts =
      user.id
      |> Profiles.verified_domains_for_user()
      |> Enum.map(& &1.domain)

    tracked_hosts = Profiles.get_tracked_site_hosts(user.id)

    ([built_in_host] ++ custom_hosts ++ tracked_hosts)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %{
        host: host,
        kind: domain_kind(host, built_in_host, custom_hosts)
      }
    end)
  end

  defp profile_host_url(user) do
    Domains.default_profile_url_for_handle(user.handle || user.username)
  end

  defp parse_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp parse_host(_), do: nil

  defp domain_kind(host, built_in_host, custom_hosts) do
    cond do
      host == built_in_host -> :built_in
      host in custom_hosts -> :custom
      true -> :tracked
    end
  end

  defp select_active_host(domains, requested_host) do
    requested_host = normalize_host(requested_host)

    cond do
      is_binary(requested_host) and Enum.any?(domains, &(&1.host == requested_host)) ->
        requested_host

      domains != [] ->
        List.first(domains).host

      true ->
        nil
    end
  end

  defp merge_domain_breakdown(domains, rows) do
    rows_by_host = Map.new(rows, &{&1.host, &1})

    Enum.map(domains, fn domain ->
      stats = Map.get(rows_by_host, domain.host, %{views: 0, unique_visitors: 0, views_today: 0})
      Map.merge(domain, stats)
    end)
  end

  defp max_daily_views([]), do: 0
  defp max_daily_views(daily_views), do: Enum.max_by(daily_views, & &1.count).count

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_host(_), do: nil
end
