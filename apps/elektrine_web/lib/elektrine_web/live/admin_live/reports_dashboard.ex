defmodule ElektrineWeb.AdminLive.ReportsDashboard do
  use ElektrineWeb, :live_view

  alias Elektrine.Messaging
  alias Elektrine.Reports
  import ElektrineWeb.Components.User.Avatar

  @impl true
  def mount(_params, _session, socket) do
    # Admin access is now verified by the AuthHooks.on_mount(:require_admin_user)
    {:ok,
     socket
     |> assign(:page_title, "Reports Dashboard")
     |> assign(:request_path, "/pripyat/reports")
     |> assign(:filter_status, "pending")
     |> assign(:filter_type, "all")
     |> assign(:filter_priority, "all")
     |> assign(:page, 1)
     |> assign(:per_page, 25)
     |> assign(:reports, [])
     |> assign(:reports_total_count, 0)
     |> assign(:total_pages, 1)
     |> assign(:selected_report, nil)
     |> assign(:stats, %{})
     |> load_reports()
     |> load_stats()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_filters(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <.section_header
        eyebrow="Moderation"
        title="Reports"
        description="Review, triage, and resolve user reports across messages, users, and conversations."
      >
        <:actions>
          <.action_toolbar>
            <.link href={~p"/pripyat/content-moderation"} class="btn btn-sm btn-ghost">
              <.icon name="hero-shield-exclamation" class="w-4 h-4" /> Moderation Queue
            </.link>
            <.link href={~p"/pripyat/content-moderation?type=chat"} class="btn btn-sm btn-ghost">
              <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> Chat Queue
            </.link>
          </.action_toolbar>
        </:actions>
      </.section_header>

      <div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
        <button
          phx-click="set_filter_status"
          phx-value-status="pending"
          class={[
            "rounded-box border border-base-300 bg-base-200/60 px-4 py-4 text-left shadow-sm transition",
            if(@filter_status == "pending",
              do: "border-warning/30 bg-warning/10 shadow-md",
              else: "border-base-content/10 hover:-translate-y-0.5 hover:border-warning/30"
            )
          ]}
        >
          <div class="text-[11px] font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Pending
          </div>
          <div class="mt-2 text-3xl font-semibold text-warning">{@stats[:pending] || 0}</div>
          <div class="mt-2 text-xs text-base-content/55">Needs initial review.</div>
        </button>

        <button
          phx-click="set_filter_status"
          phx-value-status="reviewing"
          class={[
            "rounded-box border border-base-300 bg-base-200/60 px-4 py-4 text-left shadow-sm transition",
            if(@filter_status == "reviewing",
              do: "border-info/30 bg-info/10 shadow-md",
              else: "border-base-content/10 hover:-translate-y-0.5 hover:border-info/30"
            )
          ]}
        >
          <div class="text-[11px] font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Reviewing
          </div>
          <div class="mt-2 text-3xl font-semibold text-info">{@stats[:reviewing] || 0}</div>
          <div class="mt-2 text-xs text-base-content/55">In progress.</div>
        </button>

        <button
          phx-click="set_filter_status"
          phx-value-status="resolved"
          class={[
            "rounded-box border border-base-300 bg-base-200/60 px-4 py-4 text-left shadow-sm transition",
            if(@filter_status == "resolved",
              do: "border-success/30 bg-success/10 shadow-md",
              else: "border-base-content/10 hover:-translate-y-0.5 hover:border-success/30"
            )
          ]}
        >
          <div class="text-[11px] font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Resolved
          </div>
          <div class="mt-2 text-3xl font-semibold text-success">{@stats[:resolved] || 0}</div>
          <div class="mt-2 text-xs text-base-content/55">Closed with action.</div>
        </button>

        <button
          phx-click="set_filter_status"
          phx-value-status="all"
          class={[
            "rounded-box border border-base-300 bg-base-200/60 px-4 py-4 text-left shadow-sm transition",
            if(@filter_status == "all",
              do: "border-error/30 bg-error/10 shadow-md",
              else: "border-base-content/10 hover:-translate-y-0.5 hover:border-error/30"
            )
          ]}
        >
          <div class="text-[11px] font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Critical Pending
          </div>
          <div class="mt-2 text-3xl font-semibold text-error">{@stats[:critical] || 0}</div>
          <div class="mt-2 text-xs text-base-content/55">High-risk unresolved.</div>
        </button>
      </div>

      <div class="card panel-card">
        <div class="card-body gap-4">
          <div class="tabs tabs-boxed overflow-x-auto flex-nowrap">
            <button
              phx-click="set_filter_status"
              phx-value-status="pending"
              class={status_tab_class(@filter_status, "pending")}
            >
              <.icon name="hero-clock" class="w-4 h-4 mr-1" /> Pending
            </button>
            <button
              phx-click="set_filter_status"
              phx-value-status="reviewing"
              class={status_tab_class(@filter_status, "reviewing")}
            >
              <.icon name="hero-magnifying-glass" class="w-4 h-4 mr-1" /> Reviewing
            </button>
            <button
              phx-click="set_filter_status"
              phx-value-status="resolved"
              class={status_tab_class(@filter_status, "resolved")}
            >
              <.icon name="hero-check-circle" class="w-4 h-4 mr-1" /> Resolved
            </button>
            <button
              phx-click="set_filter_status"
              phx-value-status="dismissed"
              class={status_tab_class(@filter_status, "dismissed")}
            >
              <.icon name="hero-x-circle" class="w-4 h-4 mr-1" /> Dismissed
            </button>
            <button
              phx-click="set_filter_status"
              phx-value-status="all"
              class={status_tab_class(@filter_status, "all")}
            >
              <.icon name="hero-document-text" class="w-4 h-4 mr-1" /> All
            </button>
          </div>

          <form phx-change="filter_change" class="grid grid-cols-1 gap-3 md:grid-cols-3">
            <label class="form-control">
              <span class="label-text mb-1 text-sm">Status</span>
              <select name="status" class="select select-bordered">
                <option value="all" selected={@filter_status == "all"}>All statuses</option>
                <option value="pending" selected={@filter_status == "pending"}>Pending</option>
                <option value="reviewing" selected={@filter_status == "reviewing"}>Reviewing</option>
                <option value="resolved" selected={@filter_status == "resolved"}>Resolved</option>
                <option value="dismissed" selected={@filter_status == "dismissed"}>Dismissed</option>
              </select>
            </label>

            <label class="form-control">
              <span class="label-text mb-1 text-sm">Content type</span>
              <select name="type" class="select select-bordered">
                <option value="all" selected={@filter_type == "all"}>All types</option>
                <option value="user" selected={@filter_type == "user"}>User</option>
                <option value="message" selected={@filter_type == "message"}>Message</option>
                <option value="conversation" selected={@filter_type == "conversation"}>
                  Conversation
                </option>
              </select>
            </label>

            <label class="form-control">
              <span class="label-text mb-1 text-sm">Priority</span>
              <select name="priority" class="select select-bordered">
                <option value="all" selected={@filter_priority == "all"}>All priorities</option>
                <option value="critical" selected={@filter_priority == "critical"}>Critical</option>
                <option value="high" selected={@filter_priority == "high"}>High</option>
                <option value="normal" selected={@filter_priority == "normal"}>Normal</option>
                <option value="low" selected={@filter_priority == "low"}>Low</option>
              </select>
            </label>
          </form>

          <div class="flex flex-wrap gap-2 text-xs">
            <span class="badge badge-outline">Status: {String.capitalize(@filter_status)}</span>
            <span class="badge badge-outline">Type: {String.capitalize(@filter_type)}</span>
            <span class="badge badge-outline">Priority: {String.capitalize(@filter_priority)}</span>
            <span class="badge badge-ghost">
              Showing {length(@reports)} of {@reports_total_count}
            </span>
          </div>
        </div>
      </div>

      <div class="card panel-card">
        <div class="card-body p-0">
          <%= if @reports == [] do %>
            <.empty_state
              icon="hero-document-magnifying-glass"
              title="No reports found"
              description="Try a different status/type/priority combination."
              size="sm"
            />
          <% else %>
            <div class="hidden lg:block overflow-x-auto overflow-y-visible">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Report</th>
                    <th>Reason</th>
                    <th>Reporter</th>
                    <th>Target</th>
                    <th>State</th>
                    <th>Timeline</th>
                    <th class="w-40">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for report <- @reports do %>
                    <tr class="hover">
                      <td>
                        <div class="font-semibold">#{report.id}</div>
                        <div class={[
                          "badge badge-outline badge-sm mt-1",
                          report_type_badge_class(report.reportable_type)
                        ]}>
                          {String.upcase(report.reportable_type || "unknown")}
                        </div>
                      </td>
                      <td>
                        <div class="max-w-xs">
                          <p class="font-medium">{format_reason(report.reason)}</p>
                          <%= if report.description do %>
                            <p class="text-xs text-base-content/70 mt-1 line-clamp-2">
                              {report.description}
                            </p>
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <%= if report.reporter do %>
                          <div class="flex items-center gap-2">
                            <.user_avatar user={report.reporter} size="xs" />
                            <div>
                              <div class="text-sm font-medium">
                                @{report.reporter.username}
                              </div>
                              <div class="text-xs text-base-content/60">
                                {report.reporter.display_name || "No display name"}
                              </div>
                            </div>
                          </div>
                        <% else %>
                          <span class="text-base-content/50">Deleted user</span>
                        <% end %>
                      </td>
                      <td>
                        <div class="flex items-center gap-2">
                          <span class="text-xs font-mono text-base-content/70">
                            {report.reportable_id}
                          </span>
                          <button
                            phx-click="view_reported_item"
                            phx-value-type={report.reportable_type}
                            phx-value-id={report.reportable_id}
                            class="btn btn-ghost btn-xs"
                          >
                            Open
                          </button>
                        </div>
                      </td>
                      <td>
                        <div class="flex flex-col gap-1">
                          <span class={["badge badge-sm", priority_badge_class(report.priority)]}>
                            {String.capitalize(report.priority || "normal")}
                          </span>
                          <span class={["badge badge-sm", status_badge_class(report.status)]}>
                            {String.capitalize(report.status || "pending")}
                          </span>
                          <%= if report.action_taken do %>
                            <span class="text-xs text-base-content/60">
                              {format_action_taken(report.action_taken)}
                            </span>
                          <% end %>
                        </div>
                      </td>
                      <td class="text-sm">
                        <div>
                          <.local_time datetime={report.inserted_at} format="date" />
                        </div>
                        <%= if report.reviewed_at do %>
                          <div class="text-xs text-base-content/70 mt-1">
                            Reviewed <.local_time datetime={report.reviewed_at} format="date" />
                          </div>
                        <% end %>
                      </td>
                      <td>
                        <div class="flex items-center gap-2">
                          <button
                            phx-click="view_report"
                            phx-value-id={report.id}
                            class="btn btn-primary btn-xs"
                          >
                            Review
                          </button>

                          <%= if report.status in ["pending", "reviewing"] do %>
                            <div class="dropdown dropdown-end dropdown-left">
                              <label tabindex="0" class="btn btn-ghost btn-xs btn-square">
                                <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                              </label>
                              <ul
                                tabindex="0"
                                class="dropdown-content z-50 menu p-2 rounded-box w-52"
                              >
                                <li>
                                  <button
                                    phx-click="quick_action"
                                    phx-value-id={report.id}
                                    phx-value-action="dismiss"
                                  >
                                    <.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
                                  </button>
                                </li>
                                <li>
                                  <button
                                    phx-click="quick_action"
                                    phx-value-id={report.id}
                                    phx-value-action="escalate"
                                    class="text-error"
                                  >
                                    <.icon name="hero-arrow-up" class="w-4 h-4" />
                                    Escalate to Critical
                                  </button>
                                </li>
                              </ul>
                            </div>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <div class="space-y-3 p-4 lg:hidden">
              <%= for report <- @reports do %>
                <article class="rounded-box border border-base-300 bg-base-200/60 px-4 py-4 shadow-sm">
                  <div class="mb-3 flex items-start justify-between gap-3">
                    <div>
                      <div class="font-semibold">Report #{report.id}</div>
                      <div class={[
                        "badge badge-outline badge-sm mt-1",
                        report_type_badge_class(report.reportable_type)
                      ]}>
                        {String.upcase(report.reportable_type || "unknown")}
                      </div>
                    </div>
                    <div class="text-xs text-base-content/70">
                      <.local_time datetime={report.inserted_at} format="date" />
                    </div>
                  </div>

                  <div class="space-y-2 text-sm">
                    <p class="font-medium">{format_reason(report.reason)}</p>
                    <%= if report.reporter do %>
                      <div class="flex items-center gap-2">
                        <.user_avatar user={report.reporter} size="xs" />
                        <span>@{report.reporter.username}</span>
                      </div>
                    <% else %>
                      <p class="text-base-content/60">Reporter: deleted user</p>
                    <% end %>
                    <div class="flex flex-wrap gap-2">
                      <span class={["badge badge-sm", priority_badge_class(report.priority)]}>
                        {String.capitalize(report.priority || "normal")}
                      </span>
                      <span class={["badge badge-sm", status_badge_class(report.status)]}>
                        {String.capitalize(report.status || "pending")}
                      </span>
                    </div>
                  </div>

                  <div class="mt-4 flex items-center gap-2">
                    <button
                      phx-click="view_report"
                      phx-value-id={report.id}
                      class="btn btn-primary btn-sm flex-1"
                    >
                      Review
                    </button>
                    <button
                      phx-click="view_reported_item"
                      phx-value-type={report.reportable_type}
                      phx-value-id={report.reportable_id}
                      class="btn btn-ghost btn-sm"
                    >
                      View Item
                    </button>
                    <%= if report.status in ["pending", "reviewing"] do %>
                      <div class="dropdown dropdown-end">
                        <label tabindex="0" class="btn btn-ghost btn-sm btn-square">
                          <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                        </label>
                        <ul
                          tabindex="0"
                          class="dropdown-content z-50 menu p-2 rounded-box w-52"
                        >
                          <li>
                            <button
                              phx-click="quick_action"
                              phx-value-id={report.id}
                              phx-value-action="dismiss"
                            >
                              <.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
                            </button>
                          </li>
                          <li>
                            <button
                              phx-click="quick_action"
                              phx-value-id={report.id}
                              phx-value-action="escalate"
                              class="text-error"
                            >
                              <.icon name="hero-arrow-up" class="w-4 h-4" /> Escalate to Critical
                            </button>
                          </li>
                        </ul>
                      </div>
                    <% end %>
                  </div>
                </article>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @total_pages > 1 do %>
        <div class="mt-4 flex items-center justify-between gap-3">
          <div class="text-sm text-base-content/70">
            Page {@page} of {@total_pages}
          </div>
          <div class="join">
            <button
              phx-click="prev_page"
              class="btn btn-sm join-item"
              disabled={@page <= 1}
            >
              Previous
            </button>
            <button
              phx-click="next_page"
              class="btn btn-sm join-item"
              disabled={@page >= @total_pages}
            >
              Next
            </button>
          </div>
        </div>
      <% end %>

      <%= if @selected_report do %>
        <div class="modal modal-open">
          <div
            class="modal-box modal-surface max-w-5xl w-full p-0 overflow-hidden"
            phx-click-away="close_report_modal"
          >
            <div class="border-b border-base-300 px-6 py-5">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h2 class="text-2xl font-bold">Report #{@selected_report.id}</h2>
                  <p class="mt-1 text-sm text-base-content/70">
                    Submitted
                    <.local_time datetime={@selected_report.inserted_at} format="datetime" />
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <span class={["badge", priority_badge_class(@selected_report.priority)]}>
                    {String.capitalize(@selected_report.priority || "normal")}
                  </span>
                  <span class={["badge", status_badge_class(@selected_report.status)]}>
                    {String.capitalize(@selected_report.status || "pending")}
                  </span>
                  <button phx-click="close_report_modal" class="btn btn-ghost btn-sm btn-square">
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            </div>

            <div class="max-h-[75vh] overflow-y-auto p-6 space-y-6">
              <div class="grid gap-4 lg:grid-cols-2">
                <section class="rounded-xl border border-base-300 bg-base-200/50 p-4 space-y-4">
                  <h3 class="font-semibold">Context</h3>

                  <div>
                    <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Reporter</div>
                    <%= if @selected_report.reporter do %>
                      <div class="flex items-center gap-3">
                        <.user_avatar user={@selected_report.reporter} size="sm" />
                        <div>
                          <p class="font-medium">
                            {@selected_report.reporter.display_name ||
                              @selected_report.reporter.username}
                          </p>
                          <p class="text-sm opacity-70">@{@selected_report.reporter.username}</p>
                        </div>
                      </div>
                    <% else %>
                      <p class="text-sm opacity-70">User deleted</p>
                    <% end %>
                  </div>

                  <div>
                    <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Reported item</div>
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={[
                        "badge badge-outline",
                        report_type_badge_class(@selected_report.reportable_type)
                      ]}>
                        {String.upcase(@selected_report.reportable_type || "unknown")}
                      </span>
                      <span class="text-xs font-mono opacity-70">
                        ID {@selected_report.reportable_id}
                      </span>
                      <button
                        phx-click="view_reported_item"
                        phx-value-type={@selected_report.reportable_type}
                        phx-value-id={@selected_report.reportable_id}
                        class="btn btn-ghost btn-xs"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View original
                      </button>
                    </div>
                  </div>

                  <%= if @selected_report.metadata && map_size(@selected_report.metadata) > 0 do %>
                    <div>
                      <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Metadata</div>
                      <div class="space-y-1 text-sm">
                        <%= for {key, value} <- @selected_report.metadata do %>
                          <p>
                            <span class="font-medium">{humanize_key(key)}:</span>
                            {if(is_binary(value), do: value, else: inspect(value))}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </section>

                <section class="rounded-xl border border-base-300 bg-base-200/50 p-4 space-y-4">
                  <h3 class="font-semibold">Reason and Resolution</h3>

                  <div>
                    <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Reason</div>
                    <div class="badge badge-error badge-lg">
                      {format_reason(@selected_report.reason)}
                    </div>
                  </div>

                  <%= if @selected_report.description do %>
                    <div>
                      <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Description</div>
                      <p class="text-sm whitespace-pre-wrap">{@selected_report.description}</p>
                    </div>
                  <% end %>

                  <div>
                    <div class="text-xs uppercase tracking-wide opacity-60 mb-1">Review status</div>
                    <%= if @selected_report.reviewed_by do %>
                      <p class="text-sm">
                        Reviewed by <strong>@{@selected_report.reviewed_by.username}</strong>
                        on <.local_time datetime={@selected_report.reviewed_at} format="date" />
                      </p>
                    <% else %>
                      <p class="text-sm opacity-70">Not reviewed yet</p>
                    <% end %>
                  </div>

                  <%= if @selected_report.resolution_notes do %>
                    <div>
                      <div class="text-xs uppercase tracking-wide opacity-60 mb-1">
                        Resolution notes
                      </div>
                      <p class="text-sm whitespace-pre-wrap">{@selected_report.resolution_notes}</p>
                    </div>
                  <% end %>
                </section>
              </div>

              <%= if @selected_report.status in ["pending", "reviewing"] do %>
                <section class="rounded-xl border border-base-300 bg-base-100 p-4">
                  <h3 class="font-semibold mb-3">Take Action</h3>
                  <form phx-submit="update_report" class="space-y-4">
                    <input type="hidden" name="report_id" value={@selected_report.id} />

                    <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
                      <label class="form-control">
                        <span class="label-text mb-1">Status</span>
                        <select name="status" class="select select-bordered">
                          <option value="reviewing" selected={@selected_report.status == "reviewing"}>
                            Reviewing
                          </option>
                          <option value="resolved" selected={@selected_report.status == "resolved"}>
                            Resolved
                          </option>
                          <option value="dismissed" selected={@selected_report.status == "dismissed"}>
                            Dismissed
                          </option>
                        </select>
                      </label>

                      <label class="form-control">
                        <span class="label-text mb-1">Priority</span>
                        <select name="priority" class="select select-bordered">
                          <option value="low" selected={@selected_report.priority == "low"}>
                            Low
                          </option>
                          <option value="normal" selected={@selected_report.priority == "normal"}>
                            Normal
                          </option>
                          <option value="high" selected={@selected_report.priority == "high"}>
                            High
                          </option>
                          <option value="critical" selected={@selected_report.priority == "critical"}>
                            Critical
                          </option>
                        </select>
                      </label>

                      <label class="form-control">
                        <span class="label-text mb-1">Action taken</span>
                        <select name="action_taken" class="select select-bordered">
                          <option value="" selected={@selected_report.action_taken in [nil, ""]}>
                            No action yet
                          </option>
                          <option
                            value="warned"
                            selected={@selected_report.action_taken == "warned"}
                          >
                            User Warned
                          </option>
                          <option
                            value="suspended"
                            selected={@selected_report.action_taken == "suspended"}
                          >
                            User Suspended
                          </option>
                          <option
                            value="banned"
                            selected={@selected_report.action_taken == "banned"}
                          >
                            User Banned
                          </option>
                          <option
                            value="content_removed"
                            selected={@selected_report.action_taken == "content_removed"}
                          >
                            Content Removed
                          </option>
                          <option
                            value="no_action"
                            selected={@selected_report.action_taken == "no_action"}
                          >
                            No Action Needed
                          </option>
                        </select>
                      </label>
                    </div>

                    <label class="form-control">
                      <span class="label-text mb-1">Resolution notes</span>
                      <textarea
                        name="resolution_notes"
                        class="textarea textarea-bordered"
                        rows="4"
                        placeholder="Document why this decision was made..."
                      >{@selected_report.resolution_notes}</textarea>
                    </label>

                    <div class="flex flex-wrap gap-2">
                      <button type="submit" class="btn btn-primary">Update Report</button>
                      <button type="button" phx-click="close_report_modal" class="btn btn-ghost">
                        Cancel
                      </button>
                    </div>
                  </form>

                  <div class="divider my-6">Quick Actions</div>
                  <div class="flex flex-wrap gap-2">
                    <%= if @selected_report.reportable_type == "user" do %>
                      <button
                        phx-click="admin_action"
                        phx-value-action="suspend_user"
                        phx-value-user_id={@selected_report.reportable_id}
                        data-confirm="Suspend this user for 7 days?"
                        class="btn btn-warning btn-sm"
                      >
                        <.icon name="hero-pause" class="w-4 h-4" /> Suspend User (7 days)
                      </button>
                      <button
                        phx-click="admin_action"
                        phx-value-action="ban_user"
                        phx-value-user_id={@selected_report.reportable_id}
                        data-confirm="Permanently ban this user?"
                        class="btn btn-secondary btn-sm"
                      >
                        <.icon name="hero-no-symbol" class="w-4 h-4" /> Ban User
                      </button>
                    <% end %>
                    <%= if @selected_report.reportable_type == "message" do %>
                      <button
                        phx-click="admin_action"
                        phx-value-action="delete_message"
                        phx-value-message_id={@selected_report.reportable_id}
                        data-confirm="Delete this message?"
                        class="btn btn-secondary btn-sm"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" /> Delete Message
                      </button>
                    <% end %>
                  </div>
                </section>
              <% end %>
            </div>

            <div class="border-t border-base-300 px-6 py-4 flex justify-end">
              <button type="button" phx-click="close_report_modal" class="btn btn-ghost">
                Close
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_report_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  # Event Handlers

  @impl true
  def handle_event("set_filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter_status, status)
     |> assign(:page, 1)
     |> load_reports()
     |> load_stats()}
  end

  @impl true
  def handle_event("filter_change", params, socket) do
    filters = %{
      status: params["status"] || socket.assigns.filter_status,
      type: params["type"] || socket.assigns.filter_type,
      priority: params["priority"] || socket.assigns.filter_priority
    }

    {:noreply,
     socket
     |> assign(:filter_status, filters.status)
     |> assign(:filter_type, filters.type)
     |> assign(:filter_priority, filters.priority)
     |> assign(:page, 1)
     |> load_reports(filters)}
  end

  def handle_event("view_report", %{"id" => id}, socket) do
    report = Reports.get_report_with_preloads!(String.to_integer(id))
    {:noreply, assign(socket, :selected_report, report)}
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply, assign(socket, :selected_report, nil)}
  end

  def handle_event("update_report", params, socket) do
    report = Reports.get_report!(String.to_integer(params["report_id"]))

    attrs = %{
      status: params["status"],
      priority: params["priority"],
      action_taken: params["action_taken"],
      resolution_notes: params["resolution_notes"],
      reviewed_by_id: socket.assigns.current_user.id
    }

    case Reports.review_report(report, attrs) do
      {:ok, _updated_report} ->
        {:noreply,
         socket
         |> put_flash(:info, "Report updated successfully")
         |> assign(:selected_report, nil)
         |> load_reports()
         |> load_stats()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update report")}
    end
  end

  def handle_event("quick_action", %{"id" => id, "action" => action}, socket) do
    report = Reports.get_report!(String.to_integer(id))

    attrs =
      case action do
        "dismiss" ->
          %{status: "dismissed", reviewed_by_id: socket.assigns.current_user.id}

        "escalate" ->
          %{priority: "critical", reviewed_by_id: socket.assigns.current_user.id}

        _ ->
          %{}
      end

    case Reports.review_report(report, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Action completed")
         |> load_reports()
         |> load_stats()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to perform action")}
    end
  end

  def handle_event("prev_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_reports()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_reports()}
  end

  def handle_event("admin_action", %{"action" => action} = params, socket) do
    # Handle admin actions like suspend/ban user, delete content
    case action do
      "suspend_user" ->
        user_id = String.to_integer(params["user_id"])
        user = Elektrine.Accounts.get_user!(user_id)

        # Suspend for 7 days by default
        suspended_until = DateTime.utc_now() |> DateTime.add(7, :day)

        case Elektrine.Accounts.suspend_user(user, %{
               suspended_until: suspended_until,
               suspension_reason: "Suspended via report ##{socket.assigns.selected_report.id}"
             }) do
          {:ok, _user} ->
            # Update the report to mark it as resolved
            if socket.assigns.selected_report do
              Reports.review_report(socket.assigns.selected_report, %{
                status: "resolved",
                action_taken: "suspended",
                reviewed_by_id: socket.assigns.current_user.id,
                resolution_notes: "User suspended for 7 days"
              })
            end

            {:noreply,
             socket
             |> put_flash(
               :info,
               "User suspended until #{Calendar.strftime(suspended_until, "%B %d, %Y")}"
             )
             |> assign(:selected_report, nil)
             |> load_reports()
             |> load_stats()}

          {:error, :cannot_suspend_admin} ->
            {:noreply,
             put_flash(socket, :error, "Admin users cannot be suspended for security reasons")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to suspend user")}
        end

      "ban_user" ->
        user_id = String.to_integer(params["user_id"])
        user = Elektrine.Accounts.get_user!(user_id)

        case Elektrine.Accounts.ban_user(user, %{
               banned_reason: "Banned via report ##{socket.assigns.selected_report.id}"
             }) do
          {:ok, _user} ->
            # Update the report to mark it as resolved
            if socket.assigns.selected_report do
              Reports.review_report(socket.assigns.selected_report, %{
                status: "resolved",
                action_taken: "banned",
                reviewed_by_id: socket.assigns.current_user.id,
                resolution_notes: "User permanently banned"
              })
            end

            {:noreply,
             socket
             |> put_flash(:info, "User has been permanently banned")
             |> assign(:selected_report, nil)
             |> load_reports()
             |> load_stats()}

          {:error, :cannot_ban_admin} ->
            {:noreply,
             put_flash(socket, :error, "Admin users cannot be banned for security reasons")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to ban user")}
        end

      "delete_message" ->
        message_id = String.to_integer(params["message_id"])

        case Messaging.admin_delete_message(message_id, socket.assigns.current_user) do
          {:ok, _message} ->
            case maybe_resolve_reports_after_message_delete(
                   message_id,
                   socket.assigns.current_user.id
                 ) do
              :ok ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Message deleted")
                 |> assign(:selected_report, nil)
                 |> load_reports()
                 |> load_stats()}

              {:error, _reason} ->
                {:noreply,
                 socket
                 |> put_flash(:error, "Message deleted, but the report could not be resolved")
                 |> load_reports()
                 |> load_stats()}
            end

          {:error, :already_deleted} ->
            {:noreply, put_flash(socket, :error, "Message has already been deleted")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Message not found")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You are not allowed to delete this message")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete message")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("view_reported_item", %{"type" => type, "id" => id}, socket) do
    case reported_item_path(type, String.to_integer(id)) do
      {:ok, path} ->
        {:noreply, redirect(socket, to: path)}

      :error ->
        {:noreply, put_flash(socket, :error, "No admin view is available for this report target")}
    end
  end

  # Private Functions

  defp maybe_resolve_reports_after_message_delete(message_id, reviewer_id) do
    reports =
      Reports.get_reports_for("message", message_id)
      |> Enum.filter(&(&1.status in ["pending", "reviewing"]))

    Enum.reduce_while(reports, :ok, fn report, :ok ->
      case Reports.review_report(Reports.get_report!(report.id), %{
             status: "resolved",
             action_taken: "content_removed",
             reviewed_by_id: reviewer_id,
             resolution_notes: "Message deleted by admin from reports dashboard"
           }) do
        {:ok, _updated_report} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_reports(socket, filters \\ %{}) do
    filters =
      Map.merge(
        %{
          status: socket.assigns.filter_status,
          reportable_type: socket.assigns.filter_type,
          priority: socket.assigns.filter_priority
        },
        filters
      )

    # Clean up filters
    filters =
      Enum.reduce(filters, %{}, fn
        {_k, "all"}, acc -> acc
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    page = socket.assigns.page || 1
    per_page = socket.assigns.per_page || 25
    result = Reports.paginate_reports(filters, page, per_page)

    socket
    |> assign(:reports, result.entries)
    |> assign(:reports_total_count, result.total_count)
    |> assign(:total_pages, result.total_pages)
    |> assign(:page, result.page)
  end

  defp load_stats(socket) do
    assign(socket, :stats, Reports.dashboard_stats())
  end

  defp apply_filters(socket, params) do
    socket
    |> assign(:filter_status, params["status"] || socket.assigns.filter_status)
    |> assign(:filter_type, params["type"] || socket.assigns.filter_type)
    |> assign(:filter_priority, params["priority"] || socket.assigns.filter_priority)
    |> load_reports()
  end

  defp reported_item_path("user", id), do: {:ok, "/pripyat/users/#{id}/edit"}

  defp reported_item_path(type, id) when type in ["message", "post"] do
    cond do
      Elektrine.Repo.get(Elektrine.Messaging.ChatMessage, id) ->
        {:ok, "/pripyat/arblarg/messages/#{id}/view"}

      Elektrine.Repo.get(Elektrine.Messaging.Message, id) ->
        {:ok, "/timeline/post/#{id}"}

      true ->
        :error
    end
  end

  defp reported_item_path(_, _id), do: :error

  defp format_reason(nil), do: "Unspecified"

  defp format_reason(reason) do
    reason
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_action_taken(nil), do: "No Action"

  defp format_action_taken(action) do
    case action do
      "warned" -> "User Warned"
      "suspended" -> "User Suspended"
      "banned" -> "User Banned"
      "content_removed" -> "Content Removed"
      "no_action" -> "No Action"
      _ -> String.capitalize(action)
    end
  end

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp status_tab_class(active_status, value) do
    "tab flex-shrink-0 gap-1 " <> if(active_status == value, do: "tab-active", else: "")
  end

  defp report_type_badge_class("user"), do: "badge-info"
  defp report_type_badge_class("message"), do: "badge-secondary"
  defp report_type_badge_class("conversation"), do: "badge-accent"
  defp report_type_badge_class(_), do: "badge-ghost"

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("reviewing"), do: "badge-info"
  defp status_badge_class("resolved"), do: "badge-success"
  defp status_badge_class("dismissed"), do: "badge-ghost"
  defp status_badge_class(_), do: ""

  defp priority_badge_class("critical"), do: "badge-error"
  defp priority_badge_class("high"), do: "badge-warning"
  defp priority_badge_class("normal"), do: "badge-info"
  defp priority_badge_class("low"), do: "badge-ghost"
  defp priority_badge_class(_), do: ""
end
