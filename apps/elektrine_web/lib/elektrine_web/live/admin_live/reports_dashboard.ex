defmodule ElektrineWeb.AdminLive.ReportsDashboard do
  use ElektrineWeb, :live_view
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
     |> assign(:reports, [])
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
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <!-- Header -->
      <div class="mb-8">
        <h1 class="text-3xl font-bold">Reports Dashboard</h1>
        <p class="text-base-content/70 mt-2">Review and manage user reports</p>
      </div>
      
    <!-- Stats Cards -->
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-figure text-warning">
            <.icon name="hero-clock" class="w-8 h-8" />
          </div>
          <div class="stat-title">Pending</div>
          <div class="stat-value text-warning">{@stats[:pending] || 0}</div>
          <div class="stat-desc">Awaiting review</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-figure text-info">
            <.icon name="hero-magnifying-glass" class="w-8 h-8" />
          </div>
          <div class="stat-title">Reviewing</div>
          <div class="stat-value text-info">{@stats[:reviewing] || 0}</div>
          <div class="stat-desc">Under investigation</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-figure text-success">
            <.icon name="hero-check-circle" class="w-8 h-8" />
          </div>
          <div class="stat-title">Resolved</div>
          <div class="stat-value text-success">{@stats[:resolved] || 0}</div>
          <div class="stat-desc">Last 30 days</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-figure text-error">
            <.icon name="hero-exclamation-triangle" class="w-8 h-8" />
          </div>
          <div class="stat-title">Critical</div>
          <div class="stat-value text-error">{@stats[:critical] || 0}</div>
          <div class="stat-desc">High priority</div>
        </div>
      </div>
      
    <!-- Quick Filter Tabs -->
      <div class="tabs tabs-boxed mb-6 overflow-x-auto flex-nowrap">
        <button
          phx-click="set_filter_status"
          phx-value-status="pending"
          class={"tab flex-shrink-0 #{if @filter_status == "pending", do: "tab-active"}"}
        >
          <.icon name="hero-clock" class="w-4 h-4 mr-1" />
          <span class="hidden sm:inline">Pending</span>
          <span class="sm:hidden text-xs">Pend</span>
        </button>
        <button
          phx-click="set_filter_status"
          phx-value-status="reviewing"
          class={"tab flex-shrink-0 #{if @filter_status == "reviewing", do: "tab-active"}"}
        >
          <.icon name="hero-magnifying-glass" class="w-4 h-4 mr-1" />
          <span class="hidden sm:inline">Under Review</span>
          <span class="sm:hidden text-xs">Review</span>
        </button>
        <button
          phx-click="set_filter_status"
          phx-value-status="resolved"
          class={"tab flex-shrink-0 #{if @filter_status == "resolved", do: "tab-active"}"}
        >
          <.icon name="hero-check-circle" class="w-4 h-4 mr-1" />
          <span class="hidden sm:inline">Resolved</span>
          <span class="sm:hidden text-xs">Done</span>
        </button>
        <button
          phx-click="set_filter_status"
          phx-value-status="dismissed"
          class={"tab flex-shrink-0 #{if @filter_status == "dismissed", do: "tab-active"}"}
        >
          <.icon name="hero-x-circle" class="w-4 h-4 mr-1" />
          <span class="hidden sm:inline">Dismissed</span>
          <span class="sm:hidden text-xs">Closed</span>
        </button>
        <button
          phx-click="set_filter_status"
          phx-value-status="all"
          class={"tab flex-shrink-0 #{if @filter_status == "all", do: "tab-active"}"}
        >
          <.icon name="hero-document-text" class="w-4 h-4 mr-1" />
          <span class="hidden sm:inline">All Reports</span>
          <span class="sm:hidden text-xs">All</span>
        </button>
      </div>
      
    <!-- Advanced Filters -->
      <div class="bg-base-200 rounded-lg shadow p-4 mb-6">
        <div class="flex flex-wrap gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Status</span>
            </label>
            <select
              name="status"
              phx-change="filter_change"
              class="select select-bordered select-sm"
            >
              <option value="all">All Statuses</option>
              <option value="pending" selected={@filter_status == "pending"}>Pending</option>
              <option value="reviewing" selected={@filter_status == "reviewing"}>Reviewing</option>
              <option value="resolved" selected={@filter_status == "resolved"}>Resolved</option>
              <option value="dismissed" selected={@filter_status == "dismissed"}>Dismissed</option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Type</span>
            </label>
            <select
              name="type"
              phx-change="filter_change"
              class="select select-bordered select-sm"
            >
              <option value="all">All Types</option>
              <option value="user" selected={@filter_type == "user"}>Users</option>
              <option value="message" selected={@filter_type == "message"}>Messages</option>
              <option value="conversation" selected={@filter_type == "conversation"}>
                Conversations
              </option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Priority</span>
            </label>
            <select
              name="priority"
              phx-change="filter_change"
              class="select select-bordered select-sm"
            >
              <option value="all">All Priorities</option>
              <option value="critical" selected={@filter_priority == "critical"}>Critical</option>
              <option value="high" selected={@filter_priority == "high"}>High</option>
              <option value="normal" selected={@filter_priority == "normal"}>Normal</option>
              <option value="low" selected={@filter_priority == "low"}>Low</option>
            </select>
          </div>
        </div>
      </div>
      
    <!-- Reports Table/Cards -->
      <div class="bg-base-200 rounded-lg shadow">
        <!-- Desktop Table -->
        <div class="hidden lg:block overflow-x-auto overflow-y-visible">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>ID</th>
                <th>Type</th>
                <th>Reason</th>
                <th>Reporter</th>
                <th>Reported Item</th>
                <th>Priority</th>
                <th>Status</th>
                <th>Date</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= if @reports == [] do %>
                <tr>
                  <td colspan="9" class="text-center py-8">
                    <.icon
                      name="hero-document-magnifying-glass"
                      class="w-12 h-12 mx-auto mb-2 opacity-50"
                    />
                    <p class="text-base-content/70">No reports found</p>
                  </td>
                </tr>
              <% else %>
                <%= for report <- @reports do %>
                  <tr class="hover">
                    <td>#{report.id}</td>
                    <td>
                      <div class="badge badge-outline">
                        {report.reportable_type}
                      </div>
                    </td>
                    <td>{format_reason(report.reason)}</td>
                    <td>
                      <%= if report.reporter do %>
                        <div class="flex items-center gap-2">
                          <div class="avatar">
                            <div class="w-6 h-6 rounded">
                              <.user_avatar user={report.reporter} size="xs" />
                            </div>
                          </div>
                          <span class="text-sm">@{report.reporter.username}</span>
                        </div>
                      <% else %>
                        <span class="text-base-content/50">Deleted User</span>
                      <% end %>
                    </td>
                    <td>
                      <button
                        phx-click="view_reported_item"
                        phx-value-type={report.reportable_type}
                        phx-value-id={report.reportable_id}
                        class="btn btn-ghost btn-xs"
                      >
                        View
                      </button>
                    </td>
                    <td>
                      <div class={["badge", priority_badge_class(report.priority)]}>
                        {report.priority}
                      </div>
                    </td>
                    <td>
                      <div class={["badge", status_badge_class(report.status)]}>
                        {report.status}
                      </div>
                      <%= if report.status in ["resolved", "dismissed"] && report.action_taken do %>
                        <div class="text-xs text-base-content/70 mt-1">
                          Action: {format_action_taken(report.action_taken)}
                        </div>
                      <% end %>
                    </td>
                    <td class="text-sm">
                      <div><.local_time datetime={report.inserted_at} format="date" /></div>
                      <%= if report.reviewed_at do %>
                        <div class="text-xs text-base-content/70">
                          Reviewed: <.local_time datetime={report.reviewed_at} format="date" />
                        </div>
                      <% end %>
                    </td>
                    <td>
                      <div class="flex gap-2">
                        <button
                          phx-click="view_report"
                          phx-value-id={report.id}
                          class="btn btn-primary btn-xs"
                        >
                          Review
                        </button>
                        <%= if report.status in ["pending", "reviewing"] do %>
                          <div class="dropdown dropdown-end dropdown-left">
                            <label tabindex="0" class="btn btn-ghost btn-xs">
                              <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                            </label>
                            <ul
                              tabindex="0"
                              class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-52 z-50"
                            >
                              <li>
                                <button
                                  phx-click="quick_action"
                                  phx-value-id={report.id}
                                  phx-value-action="dismiss"
                                  class="text-sm"
                                >
                                  <.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
                                </button>
                              </li>
                              <li>
                                <button
                                  phx-click="quick_action"
                                  phx-value-id={report.id}
                                  phx-value-action="escalate"
                                  class="text-sm text-error"
                                >
                                  <.icon name="hero-arrow-up" class="w-4 h-4" /> Escalate to Critical
                                </button>
                              </li>
                            </ul>
                          </div>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
        
    <!-- Mobile Card View -->
        <div class="lg:hidden p-4 space-y-4">
          <%= if @reports == [] do %>
            <div class="text-center py-8">
              <.icon name="hero-document-magnifying-glass" class="w-12 h-12 mx-auto mb-2 opacity-50" />
              <p class="text-base-content/70">No reports found</p>
            </div>
          <% else %>
            <%= for report <- @reports do %>
              <div class="card glass-card shadow-sm">
                <div class="card-body p-4">
                  <!-- Header Row -->
                  <div class="flex justify-between items-start mb-3">
                    <div>
                      <div class="font-semibold">Report #{report.id}</div>
                      <div class="text-sm text-base-content/70">
                        <.local_time datetime={report.inserted_at} format="date" />
                      </div>
                    </div>
                    <div class="flex gap-2">
                      <div class={["badge badge-sm", priority_badge_class(report.priority)]}>
                        {report.priority}
                      </div>
                      <div class={["badge badge-sm", status_badge_class(report.status)]}>
                        {report.status}
                      </div>
                    </div>
                  </div>
                  
    <!-- Report Details -->
                  <div class="space-y-2 text-sm">
                    <div class="flex items-center gap-2">
                      <span class="font-medium">Type:</span>
                      <div class="badge badge-outline badge-sm">
                        {report.reportable_type}
                      </div>
                    </div>

                    <div>
                      <span class="font-medium">Reason:</span> {format_reason(report.reason)}
                    </div>

                    <%= if report.reporter do %>
                      <div class="flex items-center gap-2">
                        <span class="font-medium">Reporter:</span>
                        <div class="flex items-center gap-1">
                          <div class="avatar">
                            <div class="w-5 h-5 rounded">
                              <.user_avatar user={report.reporter} size="xs" />
                            </div>
                          </div>
                          <span>@{report.reporter.username}</span>
                        </div>
                      </div>
                    <% else %>
                      <div>
                        <span class="font-medium">Reporter:</span>
                        <span class="text-base-content/50">Deleted User</span>
                      </div>
                    <% end %>

                    <%= if report.status in ["resolved", "dismissed"] && report.action_taken do %>
                      <div>
                        <span class="font-medium">Action:</span> {format_action_taken(
                          report.action_taken
                        )}
                      </div>
                    <% end %>

                    <%= if report.reviewed_at do %>
                      <div class="text-xs text-base-content/70">
                        Reviewed: <.local_time datetime={report.reviewed_at} format="date" />
                      </div>
                    <% end %>
                  </div>
                  
    <!-- Actions -->
                  <div class="flex gap-2 mt-4">
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
                          class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-52 z-50"
                        >
                          <li>
                            <button
                              phx-click="quick_action"
                              phx-value-id={report.id}
                              phx-value-action="dismiss"
                              class="text-sm"
                            >
                              <.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
                            </button>
                          </li>
                          <li>
                            <button
                              phx-click="quick_action"
                              phx-value-id={report.id}
                              phx-value-action="escalate"
                              class="text-sm text-error"
                            >
                              <.icon name="hero-arrow-up" class="w-4 h-4" /> Escalate to Critical
                            </button>
                          </li>
                        </ul>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
      
    <!-- Report Details Modal -->
      <%= if @selected_report do %>
        <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div
            class="bg-base-100 rounded-lg shadow-xl max-w-3xl w-full mx-4 max-h-[90vh] overflow-y-auto"
            phx-click-away="close_report_modal"
          >
            <div class="p-6">
              <div class="flex justify-between items-start mb-6">
                <div>
                  <h2 class="text-2xl font-bold">Report #{@selected_report.id}</h2>
                  <p class="text-base-content/70">
                    Submitted
                    <.local_time datetime={@selected_report.inserted_at} format="datetime" />
                  </p>
                </div>
                <button phx-click="close_report_modal" class="btn btn-ghost btn-sm">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
              
    <!-- Report Details -->
              <div class="space-y-6">
                <!-- Reporter Info -->
                <div>
                  <h3 class="font-semibold mb-2">Reporter</h3>
                  <%= if @selected_report.reporter do %>
                    <div class="flex items-center gap-3">
                      <div class="avatar">
                        <div class="w-10 h-10 rounded-full">
                          <.user_avatar user={@selected_report.reporter} size="md" />
                        </div>
                      </div>
                      <div>
                        <p class="font-medium">
                          {@selected_report.reporter.display_name ||
                            @selected_report.reporter.username}
                        </p>
                        <p class="text-sm text-base-content/70">
                          @{@selected_report.reporter.username}
                        </p>
                      </div>
                    </div>
                  <% else %>
                    <p class="text-base-content/50">User deleted</p>
                  <% end %>
                </div>
                
    <!-- Reported Content -->
                <div>
                  <h3 class="font-semibold mb-2">Reported Content</h3>
                  <div class="bg-base-200 rounded-lg p-4">
                    <div class="flex justify-between items-start mb-2">
                      <div class="badge badge-outline">{@selected_report.reportable_type}</div>
                      <button
                        phx-click="view_reported_item"
                        phx-value-type={@selected_report.reportable_type}
                        phx-value-id={@selected_report.reportable_id}
                        class="btn btn-ghost btn-xs"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View Original
                      </button>
                    </div>
                    <%= if @selected_report.metadata do %>
                      <div class="text-sm space-y-1">
                        <%= for {key, value} <- @selected_report.metadata do %>
                          <p><span class="font-medium">{humanize_key(key)}:</span> {value}</p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
                
    <!-- Report Reason -->
                <div>
                  <h3 class="font-semibold mb-2">Reason</h3>
                  <div class="flex items-center gap-2 mb-2">
                    <div class="badge badge-error badge-lg">
                      {format_reason(@selected_report.reason)}
                    </div>
                    <div class={["badge badge-lg", priority_badge_class(@selected_report.priority)]}>
                      {String.capitalize(@selected_report.priority)} Priority
                    </div>
                  </div>
                  <%= if @selected_report.description do %>
                    <div class="bg-base-200 rounded-lg p-4">
                      <p class="text-sm">{@selected_report.description}</p>
                    </div>
                  <% end %>
                </div>
                
    <!-- Current Status -->
                <div>
                  <h3 class="font-semibold mb-2">Status</h3>
                  <div class="flex items-center gap-4">
                    <div class={["badge badge-lg", status_badge_class(@selected_report.status)]}>
                      {String.capitalize(@selected_report.status)}
                    </div>
                    <%= if @selected_report.reviewed_by do %>
                      <p class="text-sm text-base-content/70">
                        Reviewed by @{@selected_report.reviewed_by.username} on
                        <.local_time datetime={@selected_report.reviewed_at} format="date" />
                      </p>
                    <% end %>
                  </div>
                  <%= if @selected_report.resolution_notes do %>
                    <div class="mt-2 bg-base-200 rounded-lg p-4">
                      <p class="text-sm font-medium mb-1">Resolution Notes:</p>
                      <p class="text-sm">{@selected_report.resolution_notes}</p>
                    </div>
                  <% end %>
                </div>
                
    <!-- Admin Actions -->
                <%= if @selected_report.status in ["pending", "reviewing"] do %>
                  <div>
                    <h3 class="font-semibold mb-2">Take Action</h3>
                    <form phx-submit="update_report" class="space-y-4">
                      <input type="hidden" name="report_id" value={@selected_report.id} />

                      <div class="grid grid-cols-2 gap-4">
                        <div class="form-control">
                          <label class="label">
                            <span class="label-text">Status</span>
                          </label>
                          <select name="status" class="select select-bordered">
                            <option
                              value="reviewing"
                              selected={@selected_report.status == "reviewing"}
                            >
                              Reviewing
                            </option>
                            <option value="resolved" selected={@selected_report.status == "resolved"}>
                              Resolved
                            </option>
                            <option
                              value="dismissed"
                              selected={@selected_report.status == "dismissed"}
                            >
                              Dismissed
                            </option>
                          </select>
                        </div>

                        <div class="form-control">
                          <label class="label">
                            <span class="label-text">Priority</span>
                          </label>
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
                            <option
                              value="critical"
                              selected={@selected_report.priority == "critical"}
                            >
                              Critical
                            </option>
                          </select>
                        </div>
                      </div>

                      <div class="form-control">
                        <label class="label">
                          <span class="label-text">Action Taken</span>
                        </label>
                        <select name="action_taken" class="select select-bordered">
                          <option value="">No action yet</option>
                          <option value="warned">User Warned</option>
                          <option value="suspended">User Suspended</option>
                          <option value="banned">User Banned</option>
                          <option value="content_removed">Content Removed</option>
                          <option value="no_action">No Action Needed</option>
                        </select>
                      </div>

                      <div class="form-control">
                        <label class="label">
                          <span class="label-text">Resolution Notes</span>
                        </label>
                        <textarea
                          name="resolution_notes"
                          class="textarea textarea-bordered"
                          rows="3"
                          placeholder="Add notes about your decision..."
                        >{@selected_report.resolution_notes}</textarea>
                      </div>

                      <div class="flex gap-3">
                        <button type="submit" class="btn btn-primary">
                          Update Report
                        </button>
                        <button type="button" phx-click="close_report_modal" class="btn btn-ghost">
                          Cancel
                        </button>
                      </div>
                    </form>
                    
    <!-- Quick Actions -->
                    <div class="divider">Quick Actions</div>
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
                  </div>
                <% end %>
              </div>
            </div>
          </div>
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
             |> load_reports()}

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
             |> load_reports()}

          {:error, :cannot_ban_admin} ->
            {:noreply,
             put_flash(socket, :error, "Admin users cannot be banned for security reasons")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to ban user")}
        end

      "delete_message" ->
        # Implement message deletion logic
        _message_id = String.to_integer(params["message_id"])

        {:noreply, put_flash(socket, :info, "Message deletion not yet implemented")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("view_reported_item", %{"type" => type, "id" => id}, socket) do
    # Redirect to the appropriate page based on type
    path =
      case type do
        "user" -> "/pripyat/users/#{id}"
        "message" -> "/pripyat/messages/#{id}"
        _ -> "#"
      end

    {:noreply, redirect(socket, external: path)}
  end

  # Private Functions

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

    reports = Reports.list_reports(filters)
    assign(socket, :reports, reports)
  end

  defp load_stats(socket) do
    stats = %{
      pending: Reports.count_pending_reports(),
      reviewing: Enum.count(Reports.list_reports(%{status: "reviewing"})),
      resolved: Enum.count(Reports.list_reports(%{status: "resolved"})),
      critical: Enum.count(Reports.list_reports(%{priority: "critical", status: "pending"}))
    }

    assign(socket, :stats, stats)
  end

  defp apply_filters(socket, params) do
    socket
    |> assign(:filter_status, params["status"] || socket.assigns.filter_status)
    |> assign(:filter_type, params["type"] || socket.assigns.filter_type)
    |> assign(:filter_priority, params["priority"] || socket.assigns.filter_priority)
    |> load_reports()
  end

  defp format_reason(reason) do
    reason
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

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
