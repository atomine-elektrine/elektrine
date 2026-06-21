defmodule ElektrineWeb.ProfileLive.DomainAnalytics do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.{DNS, Domains, Profiles}

  # The analytics panel runs ~13 independent aggregate queries. Running them
  # concurrently turns the load time from the sum of every query into the slowest
  # single query. Bounded so one user's load can't exhaust the DB pool.
  @analytics_max_concurrency 8
  @analytics_query_timeout 20_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Domain Analytics")
     |> assign(:domains, [])
     |> assign(:domain_breakdown, [])
     |> assign(:analytics_cache, %{})
     |> assign_pending_domain_analytics(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    domains = domain_targets(user)
    # The per-domain breakdown is global (independent of the selected domain), so
    # carry the last loaded counts forward instead of blanking the table to zeros
    # on every switch. The async refresh updates it once the new load lands.
    domain_breakdown = carry_forward_domain_breakdown(socket.assigns[:domain_breakdown], domains)
    active_domain = select_active_domain(domains, params["host"], params["zone_id"])

    {:noreply,
     socket
     |> assign(:domains, domains)
     |> assign(:domain_breakdown, domain_breakdown)
     |> assign_pending_domain_analytics(active_domain)
     |> maybe_load_domain_analytics(domains, active_domain)}
  end

  @impl true
  def handle_info({:load_domain_analytics, load_key, domains, active_domain}, socket) do
    if socket.assigns.analytics_load_key == load_key do
      {:noreply, assign_domain_analytics(socket, domains, active_domain)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  attr :active_host, :string, default: nil

  def domain_analytics_skeleton(assigns) do
    ~H"""
    <div class="space-y-6" aria-busy="true" aria-label="Loading analytics">
      <div class="card panel-card border border-base-300">
        <div class="card-body p-4">
          <div class="flex items-center gap-3 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-sm"></span>
            <span>Loading analytics{if @active_host, do: " for #{@active_host}"}...</span>
          </div>
        </div>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <%= for _index <- 1..5 do %>
          <div class="card panel-card">
            <div class="card-body p-4 space-y-3">
              <.skeleton type="text" class="w-24" />
              <.skeleton type="text" class="h-8 w-32" />
            </div>
          </div>
        <% end %>
      </div>

      <div class="card panel-card">
        <div class="card-body p-6 space-y-5">
          <div class="flex items-start justify-between gap-4">
            <div class="space-y-2">
              <.skeleton type="text" class="h-5 w-32" />
              <.skeleton type="text" class="w-72 max-w-full" />
            </div>
            <.skeleton type="button" class="hidden sm:block" />
          </div>

          <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <%= for _index <- 1..4 do %>
              <div class="card bg-base-200/60">
                <div class="card-body p-4 space-y-3">
                  <.skeleton type="text" class="w-28" />
                  <.skeleton type="text" class="h-8 w-24" />
                </div>
              </div>
            <% end %>
          </div>

          <div class="card bg-base-200/40">
            <div class="card-body p-6 space-y-4">
              <.skeleton type="text" class="h-5 w-32" />
              <.skeleton type="text" class="h-72 w-full rounded-xl" />
            </div>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div class="card panel-card">
          <div class="card-body p-6 space-y-4">
            <.skeleton type="text" class="h-5 w-36" />
            <.skeleton type="text" class="h-72 w-full rounded-xl" />
          </div>
        </div>

        <div class="space-y-6">
          <%= for _index <- 1..2 do %>
            <div class="card panel-card">
              <div class="card-body p-6 space-y-4">
                <.skeleton type="text" class="h-5 w-32" />
                <%= for _row <- 1..3 do %>
                  <div class="rounded-lg bg-base-200 px-4 py-3 space-y-2">
                    <.skeleton type="text" class="w-4/5" />
                    <.skeleton type="text" class="w-2/5" />
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp maybe_load_domain_analytics(socket, _domains, nil) do
    socket
    |> assign(:analytics_loading, false)
  end

  defp maybe_load_domain_analytics(socket, domains, active_domain) do
    if connected?(socket) do
      send(
        self(),
        {:load_domain_analytics, socket.assigns.analytics_load_key, domains, active_domain}
      )
    end

    socket
  end

  defp assign_pending_domain_analytics(socket, active_domain) do
    domains = socket.assigns[:domains] || []
    analytics_cache = socket.assigns[:analytics_cache] || %{}
    load_key = domain_load_key(active_domain)
    cached_analytics = Map.get(analytics_cache, load_key)

    analytics_data =
      if cached_analytics do
        Map.put(
          cached_analytics,
          :domain_breakdown,
          Map.get(cached_analytics, :domain_breakdown) || socket.assigns[:domain_breakdown]
        )
      else
        empty_domain_analytics_data(domains, socket.assigns[:domain_breakdown])
      end

    socket
    |> assign(:analytics_cache, analytics_cache)
    |> assign(:analytics_load_key, load_key)
    |> assign(:analytics_loading, not is_nil(active_domain))
    |> assign(:analytics_cached, not is_nil(cached_analytics))
    |> assign(:active_domain, active_domain)
    |> assign(:active_host, active_domain && active_domain.host)
    |> assign(analytics_data)
  end

  defp assign_domain_analytics(socket, domains, active_domain) do
    load_key = domain_load_key(active_domain)
    active_host = active_domain && active_domain.host
    analytics_data = domain_analytics_data(domains, active_domain)
    analytics_cache = socket.assigns[:analytics_cache] || %{}

    socket
    |> assign(:analytics_cache, Map.put(analytics_cache, load_key, analytics_data))
    |> assign(:analytics_loading, false)
    |> assign(:analytics_cached, true)
    |> assign(:active_domain, active_domain)
    |> assign(:active_host, active_host)
    |> assign(analytics_data)
  end

  defp empty_domain_analytics_data(domains, existing_domain_breakdown) do
    %{
      stats: empty_public_site_stats(),
      domain_breakdown: existing_domain_breakdown || merge_domain_breakdown(domains, []),
      top_pages: [],
      top_referrers: [],
      daily_views: [],
      display_days: [],
      max_daily_views: 0,
      dns_stats: empty_dns_stats(),
      dns_query_types: [],
      dns_top_names: [],
      dns_top_nxdomain_names: [],
      dns_rcode_breakdown: [],
      dns_transport_breakdown: [],
      dns_hourly_queries: [],
      dns_display_hours: [],
      max_dns_hourly_queries: 0,
      dns_daily_queries: [],
      dns_display_days: [],
      max_dns_daily_queries: 0
    }
  end

  defp domain_analytics_data(domains, active_domain) do
    domain_hosts = Enum.map(domains, & &1.host)
    active_site_scope = active_site_scope(active_domain, domain_hosts)

    defaults = %{
      stats: empty_public_site_stats(),
      domain_breakdown_rows: [],
      top_pages: [],
      top_referrers: [],
      daily_views: [],
      dns_stats: empty_dns_stats(),
      dns_query_types: [],
      dns_top_names: [],
      dns_top_nxdomain_names: [],
      dns_rcode_breakdown: [],
      dns_transport_breakdown: [],
      dns_hourly_queries: [],
      dns_daily_queries: []
    }

    results =
      run_analytics_queries(
        [
          stats: fn -> Profiles.get_public_site_view_stats(active_site_scope) end,
          domain_breakdown_rows: fn -> Profiles.get_public_site_domain_breakdown(domain_hosts) end,
          top_pages: fn -> Profiles.get_public_site_top_pages(active_site_scope, 10) end,
          top_referrers: fn -> Profiles.get_public_site_top_referrers(active_site_scope, 10) end,
          daily_views: fn -> Profiles.get_public_site_daily_view_counts(30, active_site_scope) end,
          dns_stats: fn -> dns_stats(active_domain) end,
          dns_query_types: fn -> dns_query_types(active_domain) end,
          dns_top_names: fn -> dns_top_names(active_domain) end,
          dns_top_nxdomain_names: fn -> dns_top_nxdomain_names(active_domain) end,
          dns_rcode_breakdown: fn -> dns_rcode_breakdown(active_domain) end,
          dns_transport_breakdown: fn -> dns_transport_breakdown(active_domain) end,
          dns_hourly_queries: fn -> dns_hourly_queries(active_domain) end,
          dns_daily_queries: fn -> dns_daily_queries(active_domain) end
        ],
        defaults
      )

    daily_views = results.daily_views
    dns_hourly_queries = results.dns_hourly_queries
    dns_daily_queries = results.dns_daily_queries

    %{
      stats: results.stats,
      domain_breakdown: merge_domain_breakdown(domains, results.domain_breakdown_rows),
      top_pages: results.top_pages,
      top_referrers: results.top_referrers,
      daily_views: daily_views,
      display_days: Enum.filter(daily_views, &(&1.count > 0)) |> Enum.reverse(),
      max_daily_views: max_daily_views(daily_views),
      dns_stats: results.dns_stats,
      dns_query_types: results.dns_query_types,
      dns_top_names: results.dns_top_names,
      dns_top_nxdomain_names: results.dns_top_nxdomain_names,
      dns_rcode_breakdown: results.dns_rcode_breakdown,
      dns_transport_breakdown: results.dns_transport_breakdown,
      dns_hourly_queries: dns_hourly_queries,
      dns_display_hours: Enum.filter(dns_hourly_queries, &(&1.count > 0)),
      max_dns_hourly_queries: max_hourly_queries(dns_hourly_queries),
      dns_daily_queries: dns_daily_queries,
      dns_display_days: Enum.filter(dns_daily_queries, &(&1.count > 0)) |> Enum.reverse(),
      max_dns_daily_queries: max_daily_views(dns_daily_queries)
    }
  end

  # Runs each {key, thunk} concurrently and merges the results over `defaults`.
  # A query that times out or raises keeps its default instead of failing the
  # whole panel, so one slow/broken metric can't blank every chart.
  defp run_analytics_queries(jobs, defaults) do
    jobs
    |> Task.async_stream(
      fn {key, fun} -> {key, safe_run(fun)} end,
      max_concurrency: @analytics_max_concurrency,
      timeout: @analytics_query_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(defaults, fn
      {:ok, {key, {:ok, value}}}, acc -> Map.put(acc, key, value)
      {:ok, {_key, :error}}, acc -> acc
      {:exit, _reason}, acc -> acc
    end)
  end

  defp safe_run(fun) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.error("Domain analytics query failed: #{inspect(error)}")
      :error
  catch
    kind, reason ->
      Logger.error("Domain analytics query failed: #{inspect({kind, reason})}")
      :error
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

  defp carry_forward_domain_breakdown([_ | _] = previous, domains) do
    rows =
      Enum.map(previous, fn row ->
        %{
          host: row.host,
          views: Map.get(row, :views, 0),
          unique_visitors: Map.get(row, :unique_visitors, 0),
          views_today: Map.get(row, :views_today, 0)
        }
      end)

    merge_domain_breakdown(domains, rows)
  end

  defp carry_forward_domain_breakdown(_previous, domains), do: merge_domain_breakdown(domains, [])

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

  defp empty_public_site_stats do
    %{
      total_views: 0,
      unique_visitors: 0,
      sessions: 0,
      avg_session_duration_seconds: 0,
      bounce_rate: 0.0,
      views_today: 0,
      views_this_week: 0
    }
  end

  defp empty_dns_stats do
    %{total_queries: 0, queries_today: 0, queries_this_week: 0, nxdomain_queries: 0}
  end

  defp domain_load_key(%{host: host, dns_zone_id: zone_id}), do: {host, zone_id}
  defp domain_load_key(_), do: nil

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

  defp format_duration(seconds) when is_number(seconds) do
    seconds = round(seconds)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes >= 60 ->
        hours = div(minutes, 60)
        remaining_minutes = rem(minutes, 60)
        "#{hours}h #{remaining_minutes}m"

      minutes > 0 ->
        "#{minutes}m #{remaining_seconds}s"

      true ->
        "#{remaining_seconds}s"
    end
  end

  defp format_duration(_), do: "0s"

  defp format_percent(value) when is_number(value), do: "#{Float.round(value, 1)}%"
  defp format_percent(_), do: "0.0%"

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

  defp dns_stats(_), do: empty_dns_stats()

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
