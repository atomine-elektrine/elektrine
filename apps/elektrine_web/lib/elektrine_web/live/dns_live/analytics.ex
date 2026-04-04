defmodule ElektrineWeb.DNSLive.Analytics do
  use ElektrineWeb, :live_view

  alias Elektrine.DNS

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    if user do
      zones = DNS.list_user_zones(user.id)
      active_zone = select_active_zone(zones, params["zone_id"])

      {:ok,
       socket
       |> assign(:page_title, "DNS Analytics")
       |> assign(:zones, zones)
       |> assign_zone_analytics(active_zone)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access DNS analytics")
       |> redirect(to: ~p"/login")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    zones = DNS.list_user_zones(socket.assigns.current_user.id)
    active_zone = select_active_zone(zones, params["zone_id"])

    {:noreply,
     socket
     |> assign(:zones, zones)
     |> assign_zone_analytics(active_zone)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl space-y-8 px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="dns" current_user={@current_user} class="mb-6" />

      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h1 class="text-3xl font-semibold tracking-tight">DNS Analytics</h1>
          <p class="mt-2 text-sm text-base-content/65">
            Query visibility for your authoritative DNS zones.
          </p>
        </div>

        <div class="flex gap-2">
          <.link navigate={~p"/dns"} class="btn btn-outline btn-sm">Manage DNS</.link>
        </div>
      </div>

      <%= if @zones == [] do %>
        <div class="card panel-card">
          <div class="card-body p-6 text-sm text-base-content/70">
            No DNS zones yet. Create a zone first to start collecting analytics.
          </div>
        </div>
      <% else %>
        <div class="grid gap-6 lg:grid-cols-[280px_minmax(0,1fr)]">
          <div class="card panel-card">
            <div class="card-body p-4 space-y-3">
              <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/55">
                Zones
              </h2>

              <div class="space-y-2">
                <%= for zone <- @zones do %>
                  <.link
                    navigate={~p"/dns/analytics?zone_id=#{zone.id}"}
                    class={zone_link_class(zone, @active_zone)}
                  >
                    <div>
                      <p class="font-medium">{zone.domain}</p>
                      <p class="text-xs text-base-content/60">{zone.status}</p>
                    </div>
                  </.link>
                <% end %>
              </div>
            </div>
          </div>

          <%= if @active_zone do %>
            <div class="space-y-6">
              <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
                <.metric_card
                  title="Total Queries"
                  value={@stats.total_queries}
                  icon="hero-globe-alt"
                />
                <.metric_card title="Queries Today" value={@stats.queries_today} icon="hero-bolt" />
                <.metric_card
                  title="This Week"
                  value={@stats.queries_this_week}
                  icon="hero-chart-bar"
                />
                <.metric_card
                  title="NXDOMAIN"
                  value={@stats.nxdomain_queries}
                  icon="hero-exclamation-triangle"
                />
              </div>

              <div class="grid gap-6 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
                <div class="card panel-card">
                  <div class="card-body p-6">
                    <h2 class="card-title text-lg">Daily Queries</h2>

                    <%= if @display_days == [] do %>
                      <div class="py-8 text-center text-sm text-base-content/55">
                        No DNS query data yet.
                      </div>
                    <% else %>
                      <div
                        class="mt-4 space-y-2 max-h-96 overflow-y-auto"
                        style="scrollbar-gutter: stable"
                      >
                        <%= for day <- @display_days do %>
                          <div class="flex items-center gap-3">
                            <span class="w-24 shrink-0 text-sm text-base-content/65">
                              {Calendar.strftime(day.date, "%b %d")}
                            </span>
                            <% width =
                              if @max_daily_queries > 0,
                                do: day.count / @max_daily_queries * 100,
                                else: 0 %>
                            <div class="relative h-6 flex-1 overflow-hidden rounded-full bg-base-200">
                              <div class="h-full rounded-full bg-primary" style={"width: #{width}%"}>
                              </div>
                              <span class="absolute inset-0 flex items-center justify-center text-xs font-medium">
                                {day.count}
                              </span>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="space-y-6">
                  <div class="card panel-card">
                    <div class="card-body p-6">
                      <h2 class="card-title text-lg">Query Types</h2>

                      <%= if @query_types == [] do %>
                        <div class="py-8 text-center text-sm text-base-content/55">
                          No query type data yet.
                        </div>
                      <% else %>
                        <div class="mt-4 space-y-3">
                          <%= for item <- @query_types do %>
                            <div class="flex items-center justify-between rounded-lg bg-base-200 px-3 py-2 text-sm">
                              <span class="font-medium">{item.qtype}</span>
                              <span class="badge badge-outline">{item.count}</span>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <div class="card panel-card">
                    <div class="card-body p-6">
                      <h2 class="card-title text-lg">Response Codes</h2>

                      <%= if @rcode_breakdown == [] do %>
                        <div class="py-8 text-center text-sm text-base-content/55">
                          No response data yet.
                        </div>
                      <% else %>
                        <div class="mt-4 space-y-3">
                          <%= for item <- @rcode_breakdown do %>
                            <div class="flex items-center justify-between rounded-lg bg-base-200 px-3 py-2 text-sm">
                              <span class="font-medium">{item.rcode}</span>
                              <span class="badge badge-outline">{item.count}</span>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <div class="card panel-card">
                <div class="card-body p-6">
                  <h2 class="card-title text-lg">Top Queried Names</h2>

                  <%= if @top_names == [] do %>
                    <div class="py-8 text-center text-sm text-base-content/55">
                      No name-level query data yet.
                    </div>
                  <% else %>
                    <div class="mt-4 space-y-3">
                      <%= for item <- @top_names do %>
                        <div class="flex items-center justify-between rounded-lg bg-base-200 px-4 py-3">
                          <div class="min-w-0">
                            <p class="truncate font-medium">{item.qname}</p>
                          </div>
                          <span class="badge badge-primary">{item.count}</span>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true

  defp metric_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="text-sm text-base-content/65">{@title}</p>
            <p class="text-3xl font-bold">{@value}</p>
          </div>
          <div class="flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name={@icon} class="h-6 w-6" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp assign_zone_analytics(socket, %{id: zone_id} = zone) when is_integer(zone_id) do
    daily_queries = DNS.get_zone_daily_query_counts(zone.id, 30)

    socket
    |> assign(:active_zone, zone)
    |> assign(:stats, DNS.get_zone_query_stats(zone.id))
    |> assign(:query_types, DNS.get_zone_query_type_breakdown(zone.id, 10))
    |> assign(:top_names, DNS.get_zone_top_names(zone.id, 10))
    |> assign(:rcode_breakdown, DNS.get_zone_rcode_breakdown(zone.id))
    |> assign(:daily_queries, daily_queries)
    |> assign(:display_days, Enum.filter(daily_queries, &(&1.count > 0)) |> Enum.reverse())
    |> assign(:max_daily_queries, max_daily_queries(daily_queries))
  end

  defp assign_zone_analytics(socket, _zone) do
    socket
    |> assign(:active_zone, nil)
    |> assign(:stats, %{
      total_queries: 0,
      queries_today: 0,
      queries_this_week: 0,
      nxdomain_queries: 0
    })
    |> assign(:query_types, [])
    |> assign(:top_names, [])
    |> assign(:rcode_breakdown, [])
    |> assign(:daily_queries, [])
    |> assign(:display_days, [])
    |> assign(:max_daily_queries, 0)
  end

  defp max_daily_queries([]), do: 0

  defp max_daily_queries(daily_queries),
    do: daily_queries |> Enum.max_by(& &1.count) |> Map.fetch!(:count)

  defp select_active_zone([], _zone_id), do: nil
  defp select_active_zone(zones, nil), do: List.first(zones)

  defp select_active_zone(zones, zone_id) do
    case Integer.parse(to_string(zone_id)) do
      {id, ""} -> Enum.find(zones, &(&1.id == id)) || List.first(zones)
      _ -> List.first(zones)
    end
  end

  defp zone_link_class(zone, active_zone) do
    base = "block rounded-xl border px-3 py-3 transition-colors "

    if active_zone && active_zone.id == zone.id do
      base <> "border-primary bg-primary/10"
    else
      base <> "border-base-300 bg-base-100 hover:bg-base-200"
    end
  end
end
