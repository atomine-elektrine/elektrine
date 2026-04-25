defmodule ElektrineWeb.ProfileLive.DomainAnalytics do
  use ElektrineWeb, :live_view

  alias Elektrine.{DNS, Domains, Profiles}

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    domains = domain_targets(user)
    active_domain = select_active_domain(domains, params["host"], params["zone_id"])

    {:ok,
     socket
     |> assign(:page_title, "Domain Analytics")
     |> assign(:domains, domains)
     |> assign_domain_analytics(user, active_domain)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    domains = domain_targets(user)
    active_domain = select_active_domain(domains, params["host"], params["zone_id"])

    {:noreply,
     socket
     |> assign(:domains, domains)
     |> assign_domain_analytics(user, active_domain)}
  end

  defp assign_domain_analytics(socket, user, active_domain) do
    active_host = active_domain && active_domain.host
    domain_hosts = Enum.map(socket.assigns[:domains] || [], & &1.host)
    domain_breakdown = Profiles.get_site_domain_breakdown(user.id, domain_hosts)
    daily_views = Profiles.get_site_daily_view_counts(user.id, 30, active_host)
    dns_daily_queries = dns_daily_queries(active_domain)
    dns_hourly_queries = dns_hourly_queries(active_domain)

    socket
    |> assign(:active_domain, active_domain)
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
    |> assign(:dns_stats, dns_stats(active_domain))
    |> assign(:dns_query_types, dns_query_types(active_domain))
    |> assign(:dns_top_names, dns_top_names(active_domain))
    |> assign(:dns_top_nxdomain_names, dns_top_nxdomain_names(active_domain))
    |> assign(:dns_rcode_breakdown, dns_rcode_breakdown(active_domain))
    |> assign(:dns_transport_breakdown, dns_transport_breakdown(active_domain))
    |> assign(:dns_hourly_queries, dns_hourly_queries)
    |> assign(:dns_display_hours, Enum.filter(dns_hourly_queries, &(&1.count > 0)))
    |> assign(:max_dns_hourly_queries, max_hourly_queries(dns_hourly_queries))
    |> assign(:dns_daily_queries, dns_daily_queries)
    |> assign(
      :dns_display_days,
      Enum.filter(dns_daily_queries, &(&1.count > 0)) |> Enum.reverse()
    )
    |> assign(:max_dns_daily_queries, max_daily_views(dns_daily_queries))
  end

  defp domain_targets(user) do
    built_in_host =
      user
      |> profile_host_url()
      |> parse_host()

    custom_hosts =
      user.id
      |> Profiles.verified_domains_for_user()
      |> Enum.map(& &1.domain)

    tracked_hosts = Profiles.get_tracked_site_hosts(user.id)
    dns_zones = DNS.list_user_zones(user)

    site_domains =
      ([built_in_host] ++ custom_hosts ++ tracked_hosts)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(fn host ->
        %{
          host: host,
          kind: domain_kind(host, built_in_host, custom_hosts),
          dns_zone_id: nil,
          dns_zone_status: nil
        }
      end)

    dns_domains =
      Enum.map(dns_zones, fn zone ->
        %{
          host: zone.domain,
          kind: :dns_only,
          dns_zone_id: zone.id,
          dns_zone_status: zone.status
        }
      end)

    (site_domains ++ dns_domains)
    |> Enum.reduce(%{}, fn domain, acc ->
      Map.update(acc, domain.host, domain, fn existing ->
        existing
        |> Map.put(:dns_zone_id, domain.dns_zone_id || existing.dns_zone_id)
        |> Map.put(:dns_zone_status, domain.dns_zone_status || existing.dns_zone_status)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.host)
  end

  defp profile_host_url(user) do
    Domains.default_profile_url_for_user(user)
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

  defp select_active_domain(domains, requested_host, requested_zone_id) do
    requested_zone_id = normalize_zone_id(requested_zone_id)
    requested_host = normalize_host(requested_host)

    cond do
      is_integer(requested_zone_id) ->
        Enum.find(domains, &(&1.dns_zone_id == requested_zone_id)) || List.first(domains)

      is_binary(requested_host) ->
        Enum.find(domains, &(&1.host == requested_host)) || List.first(domains)

      domains != [] ->
        List.first(domains)

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

  defp max_hourly_queries([]), do: 0
  defp max_hourly_queries(hourly_queries), do: Enum.max_by(hourly_queries, & &1.count).count

  defp dns_stats(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_query_stats(zone_id)

  defp dns_stats(_),
    do: %{total_queries: 0, queries_today: 0, queries_this_week: 0, nxdomain_queries: 0}

  defp dns_daily_queries(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_daily_query_counts(zone_id, 30)

  defp dns_daily_queries(_), do: []

  defp dns_hourly_queries(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_hourly_query_counts(zone_id, 24)

  defp dns_hourly_queries(_), do: []

  defp dns_query_types(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_query_type_breakdown(zone_id, 10)

  defp dns_query_types(_), do: []

  defp dns_top_names(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_top_names(zone_id, 10)

  defp dns_top_names(_), do: []

  defp dns_top_nxdomain_names(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_top_nxdomain_names(zone_id, 10)

  defp dns_top_nxdomain_names(_), do: []

  defp dns_rcode_breakdown(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_rcode_breakdown(zone_id)

  defp dns_rcode_breakdown(_), do: []

  defp dns_transport_breakdown(%{dns_zone_id: zone_id}) when is_integer(zone_id),
    do: DNS.get_zone_transport_breakdown(zone_id)

  defp dns_transport_breakdown(_), do: []

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_host(_), do: nil

  defp normalize_zone_id(zone_id) do
    case Integer.parse(to_string(zone_id)) do
      {id, ""} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
