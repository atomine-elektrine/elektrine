defmodule ElektrineWeb.AdminLive.Federation do
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.MRF.SimplePolicy
  alias Elektrine.Repo

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "Federation Management")
       |> assign(:active_tab, "instances")
       |> assign(:search_query, "")
       |> assign(:show_policy_modal, false)
       |> assign(:show_add_block_modal, false)
       |> assign(:selected_instance, nil)
       |> assign(:policy_form, %{})
       |> load_data()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    end
  end

  defp load_data(socket) do
    search = socket.assigns[:search_query] || ""

    socket
    |> assign(:instances, list_instances(search))
    |> assign(:remote_actors, list_remote_actors(search))
    |> assign(:stats, get_federation_stats())
    |> assign(:domain_stats, get_domain_stats())
    |> assign(:recent_activities, list_recent_activities())
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_data()}
  end

  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> load_data()}
  end

  def handle_event("show_policy_modal", %{"id" => id}, socket) do
    instance = Repo.get(Instance, id)

    if instance do
      policy_form =
        Instance.policy_fields()
        |> Enum.map(fn field -> {Atom.to_string(field), Map.get(instance, field, false)} end)
        |> Map.new()
        |> Map.merge(%{"reason" => instance.reason || "", "notes" => instance.notes || ""})

      {:noreply,
       socket
       |> assign(:show_policy_modal, true)
       |> assign(:selected_instance, instance)
       |> assign(:policy_form, policy_form)}
    else
      {:noreply, put_flash(socket, :error, "Instance not found")}
    end
  end

  def handle_event("show_add_block_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_add_block_modal, true)
     |> assign(:policy_form, %{
       "domain" => "",
       "reason" => "",
       "notes" => "",
       "blocked" => true,
       "silenced" => false,
       "media_removal" => false,
       "media_nsfw" => false,
       "federated_timeline_removal" => false,
       "followers_only" => false,
       "report_removal" => false,
       "avatar_removal" => false,
       "banner_removal" => false,
       "reject_deletes" => false
     })}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_policy_modal, false)
     |> assign(:show_add_block_modal, false)
     |> assign(:selected_instance, nil)}
  end

  def handle_event("update_policy_form", %{"field" => field, "value" => value}, socket) do
    policy_form = Map.put(socket.assigns.policy_form, field, parse_form_value(value))
    {:noreply, assign(socket, :policy_form, policy_form)}
  end

  def handle_event("save_policies", %{"reason" => reason, "notes" => notes}, socket) do
    instance = socket.assigns.selected_instance
    policy_form = socket.assigns.policy_form

    # Build policy attrs from form
    policy_attrs =
      Instance.policy_fields()
      |> Enum.map(fn field ->
        {field, Map.get(policy_form, Atom.to_string(field), false)}
      end)
      |> Map.new()
      |> Map.merge(%{reason: reason, notes: notes})

    changeset = Instance.policy_changeset(instance, policy_attrs, socket.assigns.current_user.id)

    case Repo.update(changeset) do
      {:ok, _updated} ->
        # Invalidate MRF cache
        SimplePolicy.invalidate_cache(instance.domain)

        {:noreply,
         socket
         |> load_data()
         |> assign(:show_policy_modal, false)
         |> assign(:selected_instance, nil)
         |> put_flash(:info, "Policies updated for #{instance.domain}")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update policies: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event(
        "add_instance",
        %{"domain" => domain, "reason" => reason, "notes" => notes},
        socket
      ) do
    policy_form = socket.assigns.policy_form

    # Normalize domain
    domain = domain |> String.trim() |> String.downcase() |> String.replace(~r/^https?:\/\//, "")

    # Build policy attrs
    policy_attrs =
      Instance.policy_fields()
      |> Enum.map(fn field ->
        {field, Map.get(policy_form, Atom.to_string(field), false)}
      end)
      |> Map.new()
      |> Map.merge(%{
        domain: domain,
        reason: reason,
        notes: notes,
        policy_applied_at: DateTime.utc_now() |> DateTime.truncate(:second),
        policy_applied_by_id: socket.assigns.current_user.id
      })

    # Check if blocked is true, set blocked_at
    policy_attrs =
      if policy_attrs[:blocked] do
        Map.put(policy_attrs, :blocked_at, DateTime.utc_now() |> DateTime.truncate(:second))
      else
        policy_attrs
      end

    changeset = Instance.changeset(%Instance{}, policy_attrs)

    case Repo.insert(changeset) do
      {:ok, _instance} ->
        # Invalidate MRF cache
        SimplePolicy.invalidate_cache(domain)

        {:noreply,
         socket
         |> load_data()
         |> assign(:show_add_block_modal, false)
         |> put_flash(:info, "Instance #{domain} has been added with policies")}

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        {:noreply, put_flash(socket, :error, "Failed to add instance: #{errors}")}
    end
  end

  def handle_event("quick_block", %{"domain" => domain}, socket) do
    case ActivityPub.block_instance(
           domain,
           "Quick block from admin",
           socket.assigns.current_user.id
         ) do
      {:ok, _instance} ->
        SimplePolicy.invalidate_cache(domain)

        {:noreply,
         socket
         |> load_data()
         |> put_flash(:info, "Instance #{domain} has been blocked")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to block instance")}
    end
  end

  def handle_event("unblock_instance", %{"id" => id}, socket) do
    instance = Repo.get(Instance, id)

    if instance do
      # Clear all policies
      attrs =
        Instance.policy_fields()
        |> Enum.map(fn field -> {field, false} end)
        |> Map.new()

      instance
      |> Instance.changeset(attrs)
      |> Repo.update()

      SimplePolicy.invalidate_cache(instance.domain)

      {:noreply,
       socket
       |> load_data()
       |> put_flash(:info, "All policies cleared for #{instance.domain}")}
    else
      {:noreply, put_flash(socket, :error, "Instance not found")}
    end
  end

  def handle_event("delete_instance", %{"id" => id}, socket) do
    instance = Repo.get(Instance, id)

    if instance do
      Repo.delete(instance)
      SimplePolicy.invalidate_cache(instance.domain)

      {:noreply,
       socket
       |> load_data()
       |> put_flash(:info, "Instance #{instance.domain} has been deleted")}
    else
      {:noreply, put_flash(socket, :error, "Instance not found")}
    end
  end

  def handle_event("refresh", _, socket) do
    SimplePolicy.invalidate_cache()

    {:noreply,
     socket
     |> load_data()
     |> put_flash(:info, "Refreshed and cache cleared")}
  end

  defp parse_form_value("true"), do: true
  defp parse_form_value("false"), do: false
  defp parse_form_value(value), do: value

  defp list_instances(search) do
    query = from(i in Instance, order_by: [desc: i.inserted_at])

    query =
      if search != "" do
        search_term = "%#{search}%"
        from(i in query, where: ilike(i.domain, ^search_term) or ilike(i.reason, ^search_term))
      else
        query
      end

    Repo.all(query)
  end

  defp list_remote_actors(search) do
    query = from(a in ActivityPub.Actor, order_by: [desc: a.last_fetched_at], limit: 100)

    query =
      if search != "" do
        search_term = "%#{search}%"

        from(a in query,
          where:
            ilike(a.username, ^search_term) or
              ilike(a.domain, ^search_term) or
              ilike(a.display_name, ^search_term)
        )
      else
        query
      end

    Repo.all(query)
  end

  defp list_recent_activities do
    from(a in ActivityPub.Activity,
      order_by: [desc: a.inserted_at],
      limit: 20
    )
    |> Repo.all()
  end

  defp get_federation_stats do
    %{
      total_actors: Repo.aggregate(ActivityPub.Actor, :count, :id),
      total_activities: Repo.aggregate(ActivityPub.Activity, :count, :id),
      pending_deliveries: length(ActivityPub.get_pending_deliveries(1000)),
      blocked_instances:
        Repo.aggregate(
          from(i in Instance, where: i.blocked == true),
          :count,
          :id
        ),
      silenced_instances:
        Repo.aggregate(
          from(i in Instance, where: i.silenced == true),
          :count,
          :id
        ),
      limited_instances:
        Repo.aggregate(
          from(i in Instance,
            where:
              i.federated_timeline_removal == true or
                i.media_removal == true or
                i.media_nsfw == true
          ),
          :count,
          :id
        ),
      unique_domains:
        Repo.aggregate(
          from(a in ActivityPub.Actor, select: a.domain, distinct: true),
          :count
        ),
      person_actors:
        Repo.aggregate(
          from(a in ActivityPub.Actor, where: a.actor_type == "Person"),
          :count,
          :id
        ),
      group_actors:
        Repo.aggregate(
          from(a in ActivityPub.Actor, where: a.actor_type == "Group"),
          :count,
          :id
        )
    }
  end

  defp get_domain_stats do
    from(a in ActivityPub.Actor,
      group_by: a.domain,
      select: {a.domain, count(a.id)},
      order_by: [desc: count(a.id)],
      limit: 20
    )
    |> Repo.all()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold">Federation Management</h1>
          <p class="text-sm opacity-70 mt-1">Manage MRF policies for remote instances</p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/pripyat/relays"} class="btn btn-sm btn-ghost">
            <.icon name="hero-signal" class="w-4 h-4" />
            <span class="hidden sm:inline ml-1">Relays</span>
          </.link>
          <button phx-click="show_add_block_modal" class="btn btn-sm btn-secondary">
            <.icon name="hero-plus" class="w-4 h-4" />
            <span class="hidden sm:inline ml-1">Add Instance</span>
          </button>
          <button phx-click="refresh" class="btn btn-sm btn-ghost">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            <span class="hidden sm:inline ml-1">Refresh</span>
          </button>
        </div>
      </div>
      
    <!-- Stats Cards -->
      <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-8 gap-2 sm:gap-4 mb-6">
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-globe-alt" class="w-4 h-4 text-primary opacity-70" />
              <span class="text-xs opacity-70">Domains</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.unique_domains}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-users" class="w-4 h-4 text-info opacity-70" />
              <span class="text-xs opacity-70">Actors</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.total_actors}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-user" class="w-4 h-4 text-success opacity-70" />
              <span class="text-xs opacity-70">People</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.person_actors}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-user-group" class="w-4 h-4 text-accent opacity-70" />
              <span class="text-xs opacity-70">Groups</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.group_actors}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-bolt" class="w-4 h-4 text-warning opacity-70" />
              <span class="text-xs opacity-70">Activities</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.total_activities}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-no-symbol" class="w-4 h-4 text-error opacity-70" />
              <span class="text-xs opacity-70">Blocked</span>
            </div>
            <div class="text-lg sm:text-xl font-bold text-error">{@stats.blocked_instances}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-adjustments-horizontal" class="w-4 h-4 text-warning opacity-70" />
              <span class="text-xs opacity-70">Limited</span>
            </div>
            <div class="text-lg sm:text-xl font-bold text-warning">{@stats.limited_instances}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-3 sm:p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-clock" class="w-4 h-4 text-secondary opacity-70" />
              <span class="text-xs opacity-70">Pending</span>
            </div>
            <div class="text-lg sm:text-xl font-bold">{@stats.pending_deliveries}</div>
          </div>
        </div>
      </div>
      
    <!-- Tabs -->
      <div class="tabs tabs-boxed mb-4 bg-base-200 p-1">
        <button
          phx-click="switch_tab"
          phx-value-tab="instances"
          class={["tab", @active_tab == "instances" && "tab-active"]}
        >
          <.icon name="hero-server-stack" class="w-4 h-4 mr-1" /> Instances
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="actors"
          class={["tab", @active_tab == "actors" && "tab-active"]}
        >
          <.icon name="hero-users" class="w-4 h-4 mr-1" /> Remote Actors
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="domains"
          class={["tab", @active_tab == "domains" && "tab-active"]}
        >
          <.icon name="hero-chart-bar" class="w-4 h-4 mr-1" /> Top Domains
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="activity"
          class={["tab", @active_tab == "activity" && "tab-active"]}
        >
          <.icon name="hero-bolt" class="w-4 h-4 mr-1" /> Activity
        </button>
      </div>
      
    <!-- Search -->
      <div class="mb-4">
        <form phx-submit="search" class="flex gap-2">
          <div class="join flex-1">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder={
                if @active_tab == "actors",
                  do: "Search actors by username or domain...",
                  else: "Search instances..."
              }
              class="input input-bordered join-item flex-1"
              phx-debounce="300"
            />
            <button type="submit" class="btn btn-primary join-item">
              <.icon name="hero-magnifying-glass" class="w-4 h-4" />
            </button>
          </div>
          <%= if @search_query != "" do %>
            <button type="button" phx-click="clear_search" class="btn btn-ghost">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          <% end %>
        </form>
      </div>
      
    <!-- Content based on active tab -->
      <%= case @active_tab do %>
        <% "instances" -> %>
          <.instances_table instances={@instances} />
        <% "actors" -> %>
          <.actors_table actors={@remote_actors} />
        <% "domains" -> %>
          <.domains_table domain_stats={@domain_stats} />
        <% "activity" -> %>
          <.activity_table activities={@recent_activities} />
      <% end %>
      
    <!-- Policy Edit Modal -->
      <%= if @show_policy_modal && @selected_instance do %>
        <.policy_modal
          instance={@selected_instance}
          policy_form={@policy_form}
        />
      <% end %>
      
    <!-- Add Instance Modal -->
      <%= if @show_add_block_modal do %>
        <.add_instance_modal policy_form={@policy_form} />
      <% end %>
    </div>
    """
  end

  defp instances_table(assigns) do
    ~H"""
    <div class="card glass-card shadow">
      <div class="card-body p-3 sm:p-6">
        <h2 class="card-title text-base sm:text-lg mb-4">
          <.icon name="hero-server-stack" class="w-5 h-5" /> Managed Instances
          <span class="badge badge-neutral">{length(@instances)}</span>
        </h2>

        <%= if length(@instances) > 0 do %>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Domain</th>
                  <th>Status</th>
                  <th class="hidden sm:table-cell">Active Policies</th>
                  <th class="hidden md:table-cell">Reason</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for instance <- @instances do %>
                  <tr>
                    <td>
                      <div class="font-mono text-sm">{instance.domain}</div>
                      <%= if String.starts_with?(instance.domain || "", "*.") do %>
                        <span class="badge badge-xs badge-info">wildcard</span>
                      <% end %>
                    </td>
                    <td>
                      <.severity_badge instance={instance} />
                    </td>
                    <td class="hidden sm:table-cell">
                      <div class="flex flex-wrap gap-1">
                        <%= for policy <- Instance.policy_summary(instance) do %>
                          <span class="badge badge-xs badge-outline">{policy}</span>
                        <% end %>
                        <%= if Instance.policy_summary(instance) == [] do %>
                          <span class="text-sm opacity-50">None</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="hidden md:table-cell text-sm opacity-70 max-w-xs truncate">
                      {instance.reason || "-"}
                    </td>
                    <td>
                      <div class="flex gap-1">
                        <button
                          phx-click="show_policy_modal"
                          phx-value-id={instance.id}
                          class="btn btn-xs btn-ghost"
                          title="Edit Policies"
                        >
                          <.icon name="hero-cog-6-tooth" class="w-3 h-3" />
                        </button>
                        <%= if Instance.has_any_policy?(instance) do %>
                          <button
                            phx-click="unblock_instance"
                            phx-value-id={instance.id}
                            class="btn btn-xs btn-success btn-ghost"
                            title="Clear All Policies"
                          >
                            <.icon name="hero-check" class="w-3 h-3" />
                          </button>
                        <% end %>
                        <button
                          phx-click="delete_instance"
                          phx-value-id={instance.id}
                          data-confirm="Delete this instance record? This cannot be undone."
                          class="btn btn-xs btn-error btn-ghost"
                          title="Delete"
                        >
                          <.icon name="hero-trash" class="w-3 h-3" />
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <div class="text-center py-12">
            <.icon name="hero-server-stack" class="w-12 h-12 mx-auto opacity-30 mb-4" />
            <p class="opacity-70">No managed instances</p>
            <p class="text-sm opacity-50 mt-1">
              Add instances to apply MRF policies
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp severity_badge(assigns) do
    ~H"""
    <%= case Instance.severity_level(@instance) do %>
      <% :blocked -> %>
        <span class="badge badge-error badge-sm">Blocked</span>
      <% :restricted -> %>
        <span class="badge badge-warning badge-sm">Restricted</span>
      <% :limited -> %>
        <span class="badge badge-info badge-sm">Limited</span>
      <% :modified -> %>
        <span class="badge badge-secondary badge-sm">Modified</span>
      <% :none -> %>
        <span class="badge badge-success badge-sm">Active</span>
    <% end %>
    """
  end

  defp policy_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">
          <.icon name="hero-cog-6-tooth" class="w-5 h-5 inline mr-2" /> MRF Policies for
          <span class="font-mono">{@instance.domain}</span>
        </h3>

        <form phx-submit="save_policies">
          <!-- Policy toggles in categories -->
          <div class="space-y-4">
            <!-- Blocking -->
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h4 class="font-semibold text-error mb-2">Blocking</h4>
                <.policy_toggle
                  field="blocked"
                  label="Block Instance"
                  description="Reject all activities from this instance (except deletes)"
                  value={@policy_form["blocked"]}
                />
                <.policy_toggle
                  field="reject_deletes"
                  label="Reject Deletes"
                  description="Also reject Delete activities (keeps content even if deleted upstream)"
                  value={@policy_form["reject_deletes"]}
                />
              </div>
            </div>
            
    <!-- Visibility -->
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h4 class="font-semibold text-warning mb-2">Visibility Restrictions</h4>
                <.policy_toggle
                  field="federated_timeline_removal"
                  label="Remove from Federated Timeline"
                  description="Hide posts from public timeline (still visible to followers)"
                  value={@policy_form["federated_timeline_removal"]}
                />
                <.policy_toggle
                  field="followers_only"
                  label="Force Followers-Only"
                  description="Convert all public posts to followers-only visibility"
                  value={@policy_form["followers_only"]}
                />
                <.policy_toggle
                  field="silenced"
                  label="Silence (Legacy)"
                  description="Legacy option - prefer using specific visibility policies"
                  value={@policy_form["silenced"]}
                />
              </div>
            </div>
            
    <!-- Media -->
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h4 class="font-semibold text-info mb-2">Media Handling</h4>
                <.policy_toggle
                  field="media_removal"
                  label="Remove Media"
                  description="Strip all media attachments from posts"
                  value={@policy_form["media_removal"]}
                />
                <.policy_toggle
                  field="media_nsfw"
                  label="Force NSFW"
                  description="Mark all media as sensitive/NSFW"
                  value={@policy_form["media_nsfw"]}
                />
                <.policy_toggle
                  field="avatar_removal"
                  label="Remove Avatars"
                  description="Strip avatar images from user profiles"
                  value={@policy_form["avatar_removal"]}
                />
                <.policy_toggle
                  field="banner_removal"
                  label="Remove Banners"
                  description="Strip header/banner images from user profiles"
                  value={@policy_form["banner_removal"]}
                />
              </div>
            </div>
            
    <!-- Moderation -->
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h4 class="font-semibold text-secondary mb-2">Moderation</h4>
                <.policy_toggle
                  field="report_removal"
                  label="Reject Reports"
                  description="Ignore Flag (report) activities from this instance"
                  value={@policy_form["report_removal"]}
                />
              </div>
            </div>
          </div>
          
    <!-- Reason and notes -->
          <div class="form-control mt-4">
            <label class="label">
              <span class="label-text">Reason (public)</span>
            </label>
            <input
              type="text"
              name="reason"
              value={@policy_form["reason"]}
              class="input input-bordered"
              placeholder="Reason shown in transparency reports"
            />
          </div>

          <div class="form-control mt-2">
            <label class="label">
              <span class="label-text">Notes (private)</span>
            </label>
            <textarea
              name="notes"
              class="textarea textarea-bordered"
              rows="2"
              placeholder="Internal notes for admins"
            >{@policy_form["notes"]}</textarea>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_modal" class="btn">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Save Policies
            </button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop" phx-click="close_modal">
        <button>close</button>
      </form>
    </div>
    """
  end

  defp policy_toggle(assigns) do
    ~H"""
    <label class="flex items-start gap-3 cursor-pointer py-2">
      <input
        type="checkbox"
        class="toggle toggle-sm"
        checked={@value}
        phx-click="update_policy_form"
        phx-value-field={@field}
        phx-value-value={to_string(!@value)}
      />
      <div class="flex-1">
        <div class="text-sm font-medium">{@label}</div>
        <div class="text-xs opacity-70">{@description}</div>
      </div>
    </label>
    """
  end

  defp add_instance_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">
          <.icon name="hero-plus" class="w-5 h-5 inline mr-2" /> Add Instance with MRF Policies
        </h3>

        <form phx-submit="add_instance">
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text">Domain</span>
            </label>
            <input
              type="text"
              name="domain"
              placeholder="example.com or *.example.com"
              class="input input-bordered font-mono"
              required
              autofocus
            />
            <label class="label">
              <span class="label-text-alt opacity-70">
                Use *.domain.com to match all subdomains
              </span>
            </label>
          </div>
          
    <!-- Quick policy presets -->
          <div class="mb-4">
            <label class="label">
              <span class="label-text">Quick Presets</span>
            </label>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                class="btn btn-xs btn-error"
                phx-click="update_policy_form"
                phx-value-field="blocked"
                phx-value-value="true"
              >
                Block
              </button>
              <button
                type="button"
                class="btn btn-xs btn-warning"
                phx-click="update_policy_form"
                phx-value-field="federated_timeline_removal"
                phx-value-value="true"
              >
                Hide from FTL
              </button>
              <button
                type="button"
                class="btn btn-xs btn-info"
                phx-click="update_policy_form"
                phx-value-field="media_nsfw"
                phx-value-value="true"
              >
                Force NSFW
              </button>
            </div>
          </div>
          
    <!-- Policy toggles -->
          <div class="space-y-2 max-h-64 overflow-y-auto">
            <.policy_toggle
              field="blocked"
              label="Block Instance"
              description="Reject all activities"
              value={@policy_form["blocked"]}
            />
            <.policy_toggle
              field="federated_timeline_removal"
              label="Remove from Federated Timeline"
              description="Hide from public timeline"
              value={@policy_form["federated_timeline_removal"]}
            />
            <.policy_toggle
              field="followers_only"
              label="Force Followers-Only"
              description="Convert public posts to followers-only"
              value={@policy_form["followers_only"]}
            />
            <.policy_toggle
              field="media_removal"
              label="Remove Media"
              description="Strip media attachments"
              value={@policy_form["media_removal"]}
            />
            <.policy_toggle
              field="media_nsfw"
              label="Force NSFW"
              description="Mark all media as sensitive"
              value={@policy_form["media_nsfw"]}
            />
            <.policy_toggle
              field="avatar_removal"
              label="Remove Avatars"
              description="Strip avatar images"
              value={@policy_form["avatar_removal"]}
            />
            <.policy_toggle
              field="banner_removal"
              label="Remove Banners"
              description="Strip banner images"
              value={@policy_form["banner_removal"]}
            />
            <.policy_toggle
              field="report_removal"
              label="Reject Reports"
              description="Ignore Flag activities"
              value={@policy_form["report_removal"]}
            />
            <.policy_toggle
              field="reject_deletes"
              label="Reject Deletes"
              description="Keep content even if deleted upstream"
              value={@policy_form["reject_deletes"]}
            />
          </div>

          <div class="form-control mt-4">
            <label class="label">
              <span class="label-text">Reason (public)</span>
            </label>
            <input
              type="text"
              name="reason"
              class="input input-bordered"
              placeholder="Spam, harassment, illegal content, etc."
            />
          </div>

          <div class="form-control mt-2">
            <label class="label">
              <span class="label-text">Notes (private)</span>
            </label>
            <textarea
              name="notes"
              class="textarea textarea-bordered"
              rows="2"
              placeholder="Internal notes"
            ></textarea>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_modal" class="btn">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Add Instance
            </button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop" phx-click="close_modal">
        <button>close</button>
      </form>
    </div>
    """
  end

  defp actors_table(assigns) do
    ~H"""
    <div class="card glass-card shadow">
      <div class="card-body p-3 sm:p-6">
        <h2 class="card-title text-base sm:text-lg mb-4">
          <.icon name="hero-users" class="w-5 h-5" /> Remote Actors
          <span class="badge badge-neutral">{length(@actors)}</span>
        </h2>

        <%= if length(@actors) > 0 do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Actor</th>
                  <th>Handle</th>
                  <th class="hidden sm:table-cell">Type</th>
                  <th class="hidden md:table-cell">Last Fetched</th>
                </tr>
              </thead>
              <tbody>
                <%= for actor <- @actors do %>
                  <tr>
                    <td>
                      <div class="flex items-center gap-2">
                        <%= if actor.avatar_url do %>
                          <img
                            src={actor.avatar_url}
                            class="w-8 h-8 rounded-full object-cover"
                            alt=""
                          />
                        <% else %>
                          <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center">
                            <.icon name="hero-user" class="w-4 h-4 opacity-50" />
                          </div>
                        <% end %>
                        <div>
                          <div class="font-medium text-sm">
                            {actor.display_name || actor.username}
                          </div>
                          <div class="text-xs opacity-50 sm:hidden">
                            @{actor.username}@{actor.domain}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td class="hidden sm:table-cell">
                      <span class="font-mono text-xs">@{actor.username}@{actor.domain}</span>
                    </td>
                    <td class="hidden sm:table-cell">
                      <span class={[
                        "badge badge-xs",
                        actor.actor_type == "Person" && "badge-info",
                        actor.actor_type == "Group" && "badge-accent",
                        actor.actor_type not in ["Person", "Group"] && "badge-neutral"
                      ]}>
                        {actor.actor_type}
                      </span>
                    </td>
                    <td class="hidden md:table-cell text-xs opacity-70">
                      <%= if actor.last_fetched_at do %>
                        {Calendar.strftime(actor.last_fetched_at, "%Y-%m-%d %H:%M")}
                      <% else %>
                        -
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <div class="text-center py-12">
            <.icon name="hero-users" class="w-12 h-12 mx-auto opacity-30 mb-4" />
            <p class="opacity-70">No remote actors found</p>
            <p class="text-sm opacity-50 mt-1">
              Remote actors will appear here as they interact with your instance
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp domains_table(assigns) do
    ~H"""
    <div class="card glass-card shadow">
      <div class="card-body p-3 sm:p-6">
        <h2 class="card-title text-base sm:text-lg mb-4">
          <.icon name="hero-chart-bar" class="w-5 h-5" /> Top Domains by Actor Count
        </h2>

        <%= if length(@domain_stats) > 0 do %>
          <div class="space-y-2">
            <%= for {domain, count} <- @domain_stats do %>
              <div class="flex items-center gap-3">
                <div class="flex-1">
                  <div class="flex items-center justify-between mb-1">
                    <span class="font-mono text-sm">{domain}</span>
                    <span class="text-sm font-medium">{count} actors</span>
                  </div>
                  <progress
                    class="progress progress-primary w-full"
                    value={count}
                    max={elem(List.first(@domain_stats), 1)}
                  >
                  </progress>
                </div>
                <button
                  phx-click="quick_block"
                  phx-value-domain={domain}
                  data-confirm="Block all activity from #{domain}?"
                  class="btn btn-xs btn-ghost btn-error"
                  title="Quick Block"
                >
                  <.icon name="hero-no-symbol" class="w-3 h-3" />
                </button>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="text-center py-12">
            <.icon name="hero-chart-bar" class="w-12 h-12 mx-auto opacity-30 mb-4" />
            <p class="opacity-70">No domain statistics available</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp activity_table(assigns) do
    ~H"""
    <div class="card glass-card shadow">
      <div class="card-body p-3 sm:p-6">
        <h2 class="card-title text-base sm:text-lg mb-4">
          <.icon name="hero-bolt" class="w-5 h-5" /> Recent Activity
          <span class="badge badge-neutral">{length(@activities)}</span>
        </h2>

        <%= if length(@activities) > 0 do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Type</th>
                  <th class="hidden sm:table-cell">Actor</th>
                  <th class="hidden md:table-cell">Object</th>
                  <th>Time</th>
                </tr>
              </thead>
              <tbody>
                <%= for activity <- @activities do %>
                  <tr>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        activity.activity_type == "Create" && "badge-success",
                        activity.activity_type == "Follow" && "badge-info",
                        activity.activity_type == "Like" && "badge-warning",
                        activity.activity_type == "Announce" && "badge-accent",
                        activity.activity_type not in ["Create", "Follow", "Like", "Announce"] &&
                          "badge-neutral"
                      ]}>
                        {activity.activity_type}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell">
                      <span class="font-mono text-xs truncate max-w-[200px] block">
                        {activity.actor_uri}
                      </span>
                    </td>
                    <td class="hidden md:table-cell">
                      <span class="font-mono text-xs truncate max-w-[200px] block opacity-70">
                        {activity.object_id || "-"}
                      </span>
                    </td>
                    <td class="text-xs opacity-70">
                      {Calendar.strftime(activity.inserted_at, "%m-%d %H:%M")}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <div class="text-center py-12">
            <.icon name="hero-bolt" class="w-12 h-12 mx-auto opacity-30 mb-4" />
            <p class="opacity-70">No recent activity</p>
            <p class="text-sm opacity-50 mt-1">Federation activity will appear here</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
