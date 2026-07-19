defmodule ElektrineWeb.AdminLive.BlueskyBridge do
  use ElektrineWeb, :live_view

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Bluesky.InboundEvent
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Oban.Job

  @inbound_events_limit 20
  @outbound_jobs_limit 20

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "Bluesky Bridge")
       |> load_data()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_data() |> put_flash(:info, "Bluesky bridge status refreshed")}
  end

  defp load_data(socket) do
    config = bluesky_config()
    now = DateTime.utc_now()
    last_24_hours = DateTime.add(now, -24, :hour)

    socket
    |> assign(:config, config)
    |> assign(:stats, stats(config, last_24_hours))
    |> assign(:reason_counts, reason_counts(last_24_hours))
    |> assign(:recent_events, recent_inbound_events())
    |> assign(:recent_jobs, recent_outbound_jobs())
  end

  defp stats(config, last_24_hours) do
    pending_job_states = ["available", "scheduled", "executing", "retryable"]

    managed_linked_users =
      if present?(config.managed_service_url) do
        Repo.aggregate(
          from(u in User,
            where: u.bluesky_enabled == true and u.bluesky_pds_url == ^config.managed_service_url
          ),
          :count,
          :id
        )
      else
        0
      end

    %{
      linked_users:
        Repo.aggregate(from(u in User, where: u.bluesky_enabled == true), :count, :id),
      ready_users:
        Repo.aggregate(
          from(u in User,
            where:
              u.bluesky_enabled == true and
                not is_nil(u.bluesky_identifier) and
                not is_nil(u.bluesky_app_password)
          ),
          :count,
          :id
        ),
      managed_linked_users: managed_linked_users,
      users_polled_24h:
        Repo.aggregate(
          from(u in User,
            where:
              u.bluesky_enabled == true and
                not is_nil(u.bluesky_inbound_last_polled_at) and
                u.bluesky_inbound_last_polled_at >= ^last_24_hours
          ),
          :count,
          :id
        ),
      mirrored_posts:
        Repo.aggregate(from(m in Message, where: not is_nil(m.bluesky_uri)), :count, :id),
      inbound_events_24h:
        Repo.aggregate(
          from(e in InboundEvent, where: e.processed_at >= ^last_24_hours),
          :count,
          :id
        ),
      pending_outbound_jobs:
        Repo.aggregate(
          from(j in Job,
            where:
              j.queue == "federation" and
                j.state in ^pending_job_states and
                fragment("?->>'action' LIKE 'mirror_%'", j.args)
          ),
          :count,
          :id
        ),
      discarded_outbound_jobs_24h:
        Repo.aggregate(
          from(j in Job,
            where:
              j.queue == "federation" and
                j.state == "discarded" and
                j.inserted_at >= ^last_24_hours and
                fragment("?->>'action' LIKE 'mirror_%'", j.args)
          ),
          :count,
          :id
        )
    }
  end

  defp reason_counts(last_24_hours) do
    from(e in InboundEvent,
      where: e.processed_at >= ^last_24_hours and not is_nil(e.reason),
      group_by: e.reason,
      select: {e.reason, count(e.id)},
      order_by: [desc: count(e.id)]
    )
    |> Repo.all()
  end

  defp recent_inbound_events do
    from(e in InboundEvent,
      left_join: u in User,
      on: u.id == e.user_id,
      order_by: [desc: e.processed_at, desc: e.id],
      limit: @inbound_events_limit,
      select: %{
        id: e.id,
        username: u.username,
        reason: e.reason,
        related_post_uri: e.related_post_uri,
        processed_at: e.processed_at
      }
    )
    |> Repo.all()
  end

  defp recent_outbound_jobs do
    from(j in Job,
      where: j.queue == "federation" and fragment("?->>'action' LIKE 'mirror_%'", j.args),
      order_by: [desc: j.id],
      limit: @outbound_jobs_limit,
      select: %{
        id: j.id,
        action: fragment("?->>'action'", j.args),
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        inserted_at: j.inserted_at
      }
    )
    |> Repo.all()
  end

  defp bluesky_config do
    config = Application.get_env(:elektrine, :bluesky, [])

    service_url = Keyword.get(config, :service_url)
    managed_service_url = Keyword.get(config, :managed_service_url) || service_url

    %{
      enabled: Keyword.get(config, :enabled, false),
      inbound_enabled: Keyword.get(config, :inbound_enabled, false),
      managed_enabled: Keyword.get(config, :managed_enabled, false),
      service_url: service_url,
      managed_service_url: managed_service_url,
      managed_domain: Keyword.get(config, :managed_domain),
      managed_admin_password_configured: present?(Keyword.get(config, :managed_admin_password)),
      inbound_limit: Keyword.get(config, :inbound_limit, 50),
      timeout_ms: Keyword.get(config, :timeout_ms, 12_000),
      max_chars: Keyword.get(config, :max_chars, 300)
    }
  end

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(value), do: not is_nil(value)

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp status_badge_classes(true), do: "badge badge-success badge-sm"
  defp status_badge_classes(false), do: "badge badge-neutral badge-sm"

  defp job_state_badge_classes("completed"), do: "badge badge-success badge-sm"
  defp job_state_badge_classes("discarded"), do: "badge badge-error badge-sm"
  defp job_state_badge_classes("retryable"), do: "badge badge-warning badge-sm"
  defp job_state_badge_classes("executing"), do: "badge badge-info badge-sm"
  defp job_state_badge_classes("scheduled"), do: "badge badge-secondary badge-sm"
  defp job_state_badge_classes(_), do: "badge badge-neutral badge-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="flex flex-col gap-6 px-5 py-6 sm:px-8 sm:py-8 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <div class="text-2xs font-semibold uppercase tracking-[0.32em] text-info/80">
                Federation
              </div>

              <h1 class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Bluesky Bridge</h1>

              <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                Monitor ATProto cross-posting, inbound sync health, and outbound mirror queue
                pressure.
              </p>

              <div class="mt-5 flex flex-wrap gap-2">
                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Linked users:
                  <span class="font-semibold text-base-content">{@stats.linked_users}</span>
                </div>

                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Mirrored posts:
                  <span class="font-semibold text-base-content">{@stats.mirrored_posts}</span>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap gap-2">
              <.button navigate={~p"/pripyat/messaging-federation"} variant="ghost" size="sm">
                <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" />
                <span class="ml-1">Chat Federation</span>
              </.button>
              <.button navigate={~p"/pripyat/federation"} variant="ghost" size="sm">
                <.icon name="hero-globe-alt" class="w-4 h-4" />
                <span class="ml-1">ActivityPub Policies</span>
              </.button>
              <.button variant="ghost" size="sm" phx-click="refresh">
                <.icon name="hero-arrow-path" class="w-4 h-4" />
                <span class="ml-1">Refresh</span>
              </.button>
            </div>
          </div>
        </:body>
      </.card>

      <div class="rounded-box border border-info/20 bg-info/10 px-4 py-3 text-sm text-base-content/75">
        <div class="flex items-start gap-3">
          <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-info" />
          <span>
            Outbound queue uses jobs named <span class="font-mono">mirror_*</span>
            in <span class="font-mono">federation</span>. Inbound sync stores tracked events in <span class="font-mono">bluesky_inbound_events</span>.
          </span>
        </div>
      </div>

      <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Bridge Enabled
          </div>

          <div class="mt-2">
            <span class={status_badge_classes(@config.enabled)}>
              {if @config.enabled, do: "enabled", else: "disabled"}
            </span>
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Inbound Sync
          </div>

          <div class="mt-2">
            <span class={status_badge_classes(@config.inbound_enabled)}>
              {if @config.inbound_enabled, do: "enabled", else: "disabled"}
            </span>
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Managed PDS
          </div>

          <div class="mt-2">
            <span class={status_badge_classes(@config.managed_enabled)}>
              {if @config.managed_enabled, do: "enabled", else: "disabled"}
            </span>
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Managed Admin Secret
          </div>

          <div class="mt-2">
            <span class={status_badge_classes(@config.managed_admin_password_configured)}>
              {if @config.managed_admin_password_configured, do: "configured", else: "missing"}
            </span>
          </div>
        </div>
      </section>

      <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Linked Users
          </div>

          <div class="mt-2 text-2xl font-semibold text-info">{@stats.linked_users}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Ready Users
          </div>

          <div class="mt-2 text-2xl font-semibold text-success">{@stats.ready_users}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Managed Linked Users
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">
            {@stats.managed_linked_users}
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Polled in 24h
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.users_polled_24h}</div>
        </div>
      </section>

      <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Mirrored Posts
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.mirrored_posts}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Inbound Events (24h)
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">
            {@stats.inbound_events_24h}
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Pending Outbound Jobs
          </div>

          <div class="mt-2 text-2xl font-semibold text-warning">
            {@stats.pending_outbound_jobs}
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Discarded Jobs (24h)
          </div>

          <div class="mt-2 text-2xl font-semibold text-error">
            {@stats.discarded_outbound_jobs_24h}
          </div>
        </div>
      </section>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Settings
            </div>

            <h2 class="mt-1 text-xl font-semibold tracking-tight">Bridge Configuration</h2>
          </div>

          <div class="grid gap-4 px-5 py-5 sm:grid-cols-2 sm:px-6 lg:grid-cols-3">
            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Service URL
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75 break-all">
                {@config.service_url || "-"}
              </div>
            </div>

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Managed Service URL
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75 break-all">
                {@config.managed_service_url || "-"}
              </div>
            </div>

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Managed Handle Domain
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75 break-all">
                {@config.managed_domain || "-"}
              </div>
            </div>

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Inbound Batch Limit
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75">
                {@config.inbound_limit}
              </div>
            </div>

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Bridge Timeout (ms)
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75">
                {@config.timeout_ms}
              </div>
            </div>

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Max Post Characters
              </div>

              <div class="mt-2 font-mono text-xs text-base-content/75">
                {@config.max_chars}
              </div>
            </div>
          </div>

          <%= if @reason_counts != [] do %>
            <div class="border-t border-base-content/10 px-5 py-5 sm:px-6">
              <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Inbound reasons (last 24h)
              </div>

              <div class="mt-3 flex flex-wrap gap-2">
                <%= for {reason, count} <- @reason_counts do %>
                  <span class="badge badge-outline">{reason}: {count}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </:body>
      </.card>

      <section class="grid gap-6 xl:grid-cols-2">
        <.card class="panel-card" body_class="p-0">
          <:body>
            <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
              <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Inbound
              </div>

              <h2 class="mt-1 text-xl font-semibold tracking-tight">Recent Inbound Events</h2>
            </div>

            <div class="px-5 py-5 sm:px-6">
              <%= if @recent_events == [] do %>
                <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-8 text-center text-sm text-base-content/55">
                  No inbound events recorded yet.
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm w-full">
                    <thead>
                      <tr>
                        <th>User</th>
                        <th>Reason</th>
                        <th>Post URI</th>
                        <th>Processed</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for event <- @recent_events do %>
                        <tr>
                          <td>{event.username || "-"}</td>
                          <td>
                            <span class="badge badge-outline badge-sm">{event.reason || "-"}</span>
                          </td>
                          <td>
                            <span class="font-mono text-xs break-all">
                              {event.related_post_uri || "-"}
                            </span>
                          </td>
                          <td class="text-xs text-base-content/60">
                            {format_datetime(event.processed_at)}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </:body>
        </.card>

        <.card class="panel-card" body_class="p-0">
          <:body>
            <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
              <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Outbound
              </div>

              <h2 class="mt-1 text-xl font-semibold tracking-tight">Recent Outbound Jobs</h2>
            </div>

            <div class="px-5 py-5 sm:px-6">
              <%= if @recent_jobs == [] do %>
                <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-8 text-center text-sm text-base-content/55">
                  No outbound mirror jobs recorded yet.
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm w-full">
                    <thead>
                      <tr>
                        <th>Action</th>
                        <th>State</th>
                        <th>Attempts</th>
                        <th>Created</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for job <- @recent_jobs do %>
                        <tr>
                          <td><span class="font-mono text-xs">{job.action || "-"}</span></td>
                          <td>
                            <span class={job_state_badge_classes(job.state)}>{job.state}</span>
                          </td>
                          <td class="font-mono text-xs">
                            {job.attempt}/{job.max_attempts}
                          </td>
                          <td class="text-xs text-base-content/60">
                            {format_datetime(job.inserted_at)}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </:body>
        </.card>
      </section>
    </div>
    """
  end
end
