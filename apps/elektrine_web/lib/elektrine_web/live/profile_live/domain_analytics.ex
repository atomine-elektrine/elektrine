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

  defp assign_domain_analytics(socket, _user, active_domain) do
    active_host = active_domain && active_domain.host
    domains = socket.assigns[:domains] || []
    domain_hosts = Enum.map(domains, & &1.host)
    active_site_scope = active_site_scope(active_domain, domain_hosts)
    domain_breakdown = Profiles.get_public_site_domain_breakdown(domain_hosts)
    daily_views = Profiles.get_public_site_daily_view_counts(30, active_site_scope)
    dns_daily_queries = dns_daily_queries(active_domain)
    dns_hourly_queries = dns_hourly_queries(active_domain)

    socket
    |> assign(:active_domain, active_domain)
    |> assign(:active_host, active_host)
    |> assign(:stats, Profiles.get_public_site_view_stats(active_site_scope))
    |> assign(
      :domain_breakdown,
      merge_domain_breakdown(domains, domain_breakdown)
    )
    |> assign(:top_pages, Profiles.get_public_site_top_pages(active_site_scope, 10))
    |> assign(:top_referrers, Profiles.get_public_site_top_referrers(active_site_scope, 10))
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
    built_in_hosts =
      user
      |> profile_host_urls()
      |> Enum.map(&parse_host/1)
      |> Enum.filter(&is_binary/1)

    custom_hosts =
      user.id
      |> Profiles.verified_domains_for_user()
      |> Enum.map(& &1.domain)

    dns_zones = DNS.list_user_zones(user)
    dns_zone_hosts = Enum.map(dns_zones, & &1.domain)

    tracked_hosts =
      user.id
      |> Profiles.get_tracked_site_hosts()
      |> Enum.reject(&platform_infrastructure_host?/1)
      |> Enum.filter(fn host ->
        host in built_in_hosts or host in custom_hosts or
          host_matches_any_zone?(host, dns_zone_hosts)
      end)

    site_domains =
      (built_in_hosts ++ custom_hosts ++ tracked_hosts)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(fn host ->
        %{
          host: host,
          kind: domain_kind(host, built_in_hosts, custom_hosts),
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
        |> Map.put(:kind, merged_domain_kind(existing.kind, domain.kind))
        |> Map.put(:dns_zone_id, domain.dns_zone_id || existing.dns_zone_id)
        |> Map.put(:dns_zone_status, domain.dns_zone_status || existing.dns_zone_status)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.host)
  end

  defp profile_host_urls(%{handle: handle, username: username} = user) do
    handle_or_username = handle || username

    if Elektrine.Accounts.User.built_in_subdomain_hosted_by_platform?(user) do
      Domains.profile_urls_for_handle(handle_or_username)
    else
      []
    end
  end

  defp profile_host_urls(_), do: []

  defp parse_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp parse_host(_), do: nil

  defp domain_kind(host, built_in_hosts, custom_hosts) do
    cond do
      host in built_in_hosts -> :built_in
      host in custom_hosts -> :custom
      true -> :tracked
    end
  end

  defp merged_domain_kind(existing_kind, new_kind) do
    if domain_kind_rank(new_kind) > domain_kind_rank(existing_kind),
      do: new_kind,
      else: existing_kind
  end

  defp domain_kind_rank(:built_in), do: 4
  defp domain_kind_rank(:custom), do: 3
  defp domain_kind_rank(:dns_only), do: 2
  defp domain_kind_rank(:tracked), do: 1
  defp domain_kind_rank(_), do: 0

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
      stats = domain_stats(domain, domains, rows_by_host)
      Map.merge(domain, stats)
    end)
  end

  defp domain_stats(%{host: host, kind: :dns_only}, domains, rows_by_host) when is_binary(host) do
    suffix = ".#{host}"

    domains
    |> Enum.filter(fn domain ->
      is_binary(domain.host) and (domain.host == host or String.ends_with?(domain.host, suffix))
    end)
    |> Enum.map(&Map.get(rows_by_host, &1.host, empty_domain_stats()))
    |> sum_domain_stats()
  end

  defp domain_stats(%{host: host}, _domains, rows_by_host) do
    Map.get(rows_by_host, host, empty_domain_stats())
  end

  defp empty_domain_stats, do: %{views: 0, unique_visitors: 0, views_today: 0}

  defp sum_domain_stats(rows) do
    Enum.reduce(rows, empty_domain_stats(), fn row, acc ->
      %{
        views: acc.views + Map.get(row, :views, 0),
        unique_visitors: acc.unique_visitors + Map.get(row, :unique_visitors, 0),
        views_today: acc.views_today + Map.get(row, :views_today, 0)
      }
    end)
  end

  defp active_site_scope(%{host: host, kind: :dns_only, dns_zone_id: zone_id}, domain_hosts)
       when is_binary(host) and is_integer(zone_id) do
    suffix = ".#{host}"

    domain_hosts
    |> Enum.filter(fn domain_host ->
      is_binary(domain_host) and (domain_host == host or String.ends_with?(domain_host, suffix))
    end)
  end

  defp active_site_scope(%{host: host}, _domain_hosts), do: host
  defp active_site_scope(_, _domain_hosts), do: nil

  defp host_matches_any_zone?(host, zone_hosts) when is_binary(host) do
    Enum.any?(zone_hosts, fn zone_host ->
      is_binary(zone_host) and (host == zone_host or String.ends_with?(host, ".#{zone_host}"))
    end)
  end

  defp host_matches_any_zone?(_, _), do: false

  defp platform_infrastructure_host?(host) when is_binary(host) do
    host = normalize_host(host)

    host in platform_infrastructure_hosts() or String.starts_with?(host || "", "admin.") or
      String.starts_with?(host || "", "www.")
  end

  defp platform_infrastructure_host?(_), do: false

  defp platform_infrastructure_hosts do
    admin_host = System.get_env("CADDY_ADMIN_HOST") || "admin.#{Domains.primary_profile_domain()}"

    (Domains.app_hosts() ++
       [
         admin_host,
         Domains.mail_base_url() |> parse_host(),
         Domains.profile_custom_domain_edge_target()
       ])
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp format_count(value) when is_integer(value) and value >= 1_000_000,
    do: "#{format_decimal(value / 1_000_000)}M"

  defp format_count(value) when is_integer(value) and value >= 1_000,
    do: "#{format_decimal(value / 1_000)}K"

  defp format_count(value) when is_number(value), do: to_string(value)
  defp format_count(_), do: "0"

  defp format_decimal(value) do
    value
    |> Float.round(1)
    |> then(fn rounded ->
      if rounded == Float.round(rounded, 0), do: trunc(rounded), else: rounded
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
