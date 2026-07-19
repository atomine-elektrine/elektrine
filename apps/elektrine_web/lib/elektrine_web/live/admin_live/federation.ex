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
       |> assign(:page_title, "ActivityPub Federation")
       |> assign(:active_tab, "instances")
       |> assign(:search_query, "")
       |> assign(:instances_page, 1)
       |> assign(:instances_per_page, 25)
       |> assign(:actors_page, 1)
       |> assign(:actors_per_page, 25)
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
    instances_page = socket.assigns[:instances_page] || 1
    instances_per_page = socket.assigns[:instances_per_page] || 25
    actors_page = socket.assigns[:actors_page] || 1
    actors_per_page = socket.assigns[:actors_per_page] || 25

    instances_page_data = list_instances(search, instances_page, instances_per_page)
    actors_page_data = list_remote_actors(search, actors_page, actors_per_page)

    socket
    |> assign(:instances, instances_page_data.entries)
    |> assign(:instances_page, instances_page_data.page)
    |> assign(:instances_total_count, instances_page_data.total_count)
    |> assign(:instances_total_pages, instances_page_data.total_pages)
    |> assign(:remote_actors, actors_page_data.entries)
    |> assign(:actors_page, actors_page_data.page)
    |> assign(:actors_total_count, actors_page_data.total_count)
    |> assign(:actors_total_pages, actors_page_data.total_pages)
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
     |> assign(:instances_page, 1)
     |> assign(:actors_page, 1)
     |> load_data()}
  end

  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:instances_page, 1)
     |> assign(:actors_page, 1)
     |> load_data()}
  end

  def handle_event("instances_prev_page", _, socket) do
    {:noreply,
     socket
     |> assign(:instances_page, socket.assigns.instances_page - 1)
     |> load_data()}
  end

  def handle_event("instances_next_page", _, socket) do
    {:noreply,
     socket
     |> assign(:instances_page, socket.assigns.instances_page + 1)
     |> load_data()}
  end

  def handle_event("actors_prev_page", _, socket) do
    {:noreply,
     socket
     |> assign(:actors_page, socket.assigns.actors_page - 1)
     |> load_data()}
  end

  def handle_event("actors_next_page", _, socket) do
    {:noreply,
     socket
     |> assign(:actors_page, socket.assigns.actors_page + 1)
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

  def handle_event("update_policy_form", %{"field" => field}, socket) do
    current = Map.get(socket.assigns.policy_form, field, false)
    policy_form = Map.put(socket.assigns.policy_form, field, !current)
    {:noreply, assign(socket, :policy_form, policy_form)}
  end

  def handle_event("sync_policy_form", params, socket) do
    updates =
      params
      |> Map.drop(["_target"])
      |> Enum.reject(fn {field, _value} -> String.starts_with?(field, "_unused_") end)
      |> Map.new(fn {field, value} -> {field, parse_form_value(value)} end)

    {:noreply, assign(socket, :policy_form, Map.merge(socket.assigns.policy_form, updates))}
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
  defp parse_form_value("on"), do: true
  defp parse_form_value("off"), do: false
  defp parse_form_value(value), do: value

  defp list_instances(search, page, per_page) do
    query = from(i in Instance, order_by: [desc: i.inserted_at])

    query =
      if Elektrine.Strings.present?(search) do
        search_term = "%#{search}%"
        from(i in query, where: ilike(i.domain, ^search_term) or ilike(i.reason, ^search_term))
      else
        query
      end

    paginate_query(query, page, per_page)
  end

  defp list_remote_actors(search, page, per_page) do
    query = from(a in ActivityPub.Actor, order_by: [desc: a.last_fetched_at])

    query =
      if Elektrine.Strings.present?(search) do
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

    paginate_query(query, page, per_page)
  end

  defp paginate_query(query, page, per_page) do
    total_count = Repo.aggregate(query, :count, :id)
    total_pages = total_pages(total_count, per_page)
    safe_page = clamp_page(page, total_pages)
    offset = (safe_page - 1) * per_page

    entries =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %{
      entries: entries,
      page: safe_page,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  defp total_pages(total_count, per_page) when total_count > 0 and per_page > 0 do
    div(total_count + per_page - 1, per_page)
  end

  defp total_pages(_, _), do: 1

  defp clamp_page(page, _total_pages) when page < 1, do: 1
  defp clamp_page(page, total_pages) when page > total_pages, do: total_pages
  defp clamp_page(page, _total_pages), do: page

  defp list_recent_activities do
    from(a in ActivityPub.Activity,
      order_by: [desc: a.inserted_at],
      limit: 20
    )
    |> Repo.all()
  end

  defp get_federation_stats do
    %{
      total_actors: approximate_table_count("activitypub_actors"),
      total_activities: approximate_table_count("activitypub_activities"),
      pending_deliveries: length(ActivityPub.get_pending_deliveries(250)),
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
      unique_domains: approximate_table_count("activitypub_instances"),
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

  defp approximate_table_count(table_name) when is_binary(table_name) do
    regclass_name =
      if String.contains?(table_name, ".") do
        table_name
      else
        "public.#{table_name}"
      end

    sql = """
    SELECT GREATEST(COALESCE(c.reltuples, 0), 0)::bigint
    FROM pg_class AS c
    WHERE c.oid = to_regclass($1)
    """

    case Repo.query(sql, [regclass_name], timeout: 500, pool_timeout: 200) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> count
      {:ok, %{rows: [[count]]}} when is_float(count) -> trunc(count)
      _ -> 0
    end
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
    <div class="admin-page">
      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="flex flex-col gap-6 px-5 py-6 sm:px-8 sm:py-8 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <div class="text-2xs font-semibold uppercase tracking-[0.32em] text-info/80">
                Federation
              </div>

              <h1 class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
                ActivityPub Federation
              </h1>

              <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                Moderate remote ActivityPub instances, actors, and activity flow without touching
                chat peering or Bluesky bridge credentials.
              </p>

              <div class="mt-5 flex items-start gap-3 rounded-box border border-info/20 bg-info/10 px-4 py-3 text-sm text-base-content/75">
                <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-info" />
                <span>
                  Use this page for ActivityPub trust and safety policy. For chat server peering use
                  Chat Federation, and for ATProto mirror health use Bluesky Bridge.
                </span>
              </div>
            </div>

            <div class="flex flex-wrap gap-2">
              <.button navigate={~p"/pripyat/messaging-federation"} variant="ghost" size="sm">
                <.icon name="hero-chat-bubble-left-right" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Chat Federation</span>
              </.button>
              <.button navigate={~p"/pripyat/bluesky-bridge"} variant="ghost" size="sm">
                <.icon name="hero-link" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Bluesky Bridge</span>
              </.button>
              <.button navigate={~p"/pripyat/relays"} variant="ghost" size="sm">
                <.icon name="hero-signal" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">ActivityPub Relays</span>
              </.button>
              <.button variant="ghost" size="sm" phx-click="refresh">
                <.icon name="hero-arrow-path" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Refresh</span>
              </.button>
              <.button variant="secondary" size="sm" phx-click="show_add_block_modal">
                <.icon name="hero-plus" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Add Policy</span>
              </.button>
            </div>
          </div>
        </:body>
      </.card>

      <section class="grid grid-cols-2 gap-3 sm:grid-cols-4 xl:grid-cols-8">
        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Domains
            </div>
            <.icon name="hero-globe-alt" class="h-4 w-4 text-primary" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.unique_domains}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Actors
            </div>
            <.icon name="hero-users" class="h-4 w-4 text-info" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.total_actors}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              People
            </div>
            <.icon name="hero-user" class="h-4 w-4 text-success" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.person_actors}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Groups
            </div>
            <.icon name="hero-user-group" class="h-4 w-4 text-accent" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">{@stats.group_actors}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Activities
            </div>
            <.icon name="hero-bolt" class="h-4 w-4 text-warning" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">
            {@stats.total_activities}
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Blocked
            </div>
            <.icon name="hero-no-symbol" class="h-4 w-4 text-error" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-error">{@stats.blocked_instances}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Limited
            </div>
            <.icon name="hero-adjustments-horizontal" class="h-4 w-4 text-warning" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-warning">{@stats.limited_instances}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4">
          <div class="flex items-center justify-between gap-2">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Pending
            </div>
            <.icon name="hero-clock" class="h-4 w-4 text-secondary" />
          </div>

          <div class="mt-2 text-2xl font-semibold text-base-content">
            {@stats.pending_deliveries}
          </div>
        </div>
      </section>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="flex flex-col gap-4 px-5 py-5 sm:px-6">
            <div class="tabs tabs-boxed w-fit bg-base-200 p-1">
              <button
                phx-click="switch_tab"
                phx-value-tab="instances"
                class={["tab", @active_tab == "instances" && "tab-active"]}
              >
                <.icon name="hero-server-stack" class="mr-1 h-4 w-4" /> Instance Policies
              </button>
              <button
                phx-click="switch_tab"
                phx-value-tab="actors"
                class={["tab", @active_tab == "actors" && "tab-active"]}
              >
                <.icon name="hero-users" class="mr-1 h-4 w-4" /> Remote Actors
              </button>
              <button
                phx-click="switch_tab"
                phx-value-tab="domains"
                class={["tab", @active_tab == "domains" && "tab-active"]}
              >
                <.icon name="hero-chart-bar" class="mr-1 h-4 w-4" /> Top Domains
              </button>
              <button
                phx-click="switch_tab"
                phx-value-tab="activity"
                class={["tab", @active_tab == "activity" && "tab-active"]}
              >
                <.icon name="hero-bolt" class="mr-1 h-4 w-4" /> Activity
              </button>
            </div>

            <form phx-submit="search" class="flex gap-2">
              <div class="join flex-1">
                <input
                  type="text"
                  name="query"
                  value={@search_query}
                  placeholder={
                    case @active_tab do
                      "actors" -> "Search actors by username or domain..."
                      "instances" -> "Search instances or reasons..."
                      _ -> "Search instances or reasons..."
                    end
                  }
                  class="input input-bordered join-item flex-1"
                  phx-debounce="300"
                  disabled={@active_tab in ["domains", "activity"]}
                />
                <.button
                  type="submit"
                  class="join-item"
                  disabled={@active_tab in ["domains", "activity"]}
                >
                  <.icon name="hero-magnifying-glass" class="h-4 w-4" />
                </.button>
              </div>
              <%= if @search_query != "" && @active_tab not in ["domains", "activity"] do %>
                <.button
                  type="button"
                  variant="ghost"
                  phx-click="clear_search"
                  data-search-clear="true"
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </.button>
              <% end %>
            </form>

            <%= if @active_tab in ["domains", "activity"] do %>
              <p class="text-xs text-base-content/55">
                Search filters only the Instance Policies and Remote Actors tabs.
              </p>
            <% end %>
          </div>
        </:body>
      </.card>

      <%= case @active_tab do %>
        <% "instances" -> %>
          <.instances_table
            instances={@instances}
            page={@instances_page}
            total_pages={@instances_total_pages}
            total_count={@instances_total_count}
          />
        <% "actors" -> %>
          <.actors_table
            actors={@remote_actors}
            page={@actors_page}
            total_pages={@actors_total_pages}
            total_count={@actors_total_count}
          />
        <% "domains" -> %>
          <.domains_table domain_stats={@domain_stats} />
        <% "activity" -> %>
          <.activity_table activities={@recent_activities} />
      <% end %>

      <%= if @show_policy_modal && @selected_instance do %>
        <.policy_modal
          instance={@selected_instance}
          policy_form={@policy_form}
        />
      <% end %>

      <%= if @show_add_block_modal do %>
        <.add_instance_modal policy_form={@policy_form} />
      <% end %>
    </div>
    """
  end

  defp instances_table(assigns) do
    ~H"""
    <.card class="panel-card" body_class="p-0">
      <:body>
        <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
          <div class="flex items-center justify-between gap-4">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Moderation
              </div>

              <h2 class="mt-1 text-xl font-semibold tracking-tight">
                ActivityPub Instance Policies
              </h2>
            </div>

            <div class="badge badge-ghost badge-sm">{@total_count}</div>
          </div>
        </div>

        <div class="px-5 py-5 sm:px-6">
          <%= if length(@instances) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table w-full">
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
                            <span class="text-sm text-base-content/50">None</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="hidden max-w-xs truncate text-sm text-base-content/70 md:table-cell">
                        {instance.reason || "-"}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.button
                            variant="ghost"
                            size="xs"
                            phx-click="show_policy_modal"
                            phx-value-id={instance.id}
                            title="Edit Policies"
                          >
                            <.icon name="hero-cog-6-tooth" class="h-3 w-3" />
                          </.button>
                          <%= if Instance.has_any_policy?(instance) do %>
                            <.button
                              variant="ghost"
                              size="xs"
                              phx-click="unblock_instance"
                              phx-value-id={instance.id}
                              title="Clear All Policies"
                            >
                              <.icon name="hero-check" class="h-3 w-3 text-success" />
                            </.button>
                          <% end %>
                          <.button
                            variant="ghost"
                            size="xs"
                            phx-click="delete_instance"
                            phx-value-id={instance.id}
                            data-confirm="Delete this instance record? This cannot be undone."
                            title="Delete"
                          >
                            <.icon name="hero-trash" class="h-3 w-3 text-error" />
                          </.button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-10 text-center">
              <.icon name="hero-server-stack" class="mx-auto h-10 w-10 text-base-content/25" />

              <p class="mt-3 text-sm text-base-content/60">
                No ActivityPub instance policies configured
              </p>

              <p class="mt-1 text-sm text-base-content/45">
                Add an instance to apply MRF moderation controls
              </p>
            </div>
          <% end %>
        </div>

        <%= if @total_pages > 1 do %>
          <div class="flex items-center justify-between border-t border-base-content/10 px-5 py-4 sm:px-6">
            <span class="text-xs text-base-content/60">Page {@page} of {@total_pages}</span>
            <div class="join">
              <.button
                variant="default"
                size="sm"
                class="join-item"
                phx-click="instances_prev_page"
                disabled={@page <= 1}
              >
                Previous
              </.button>
              <.button
                variant="default"
                size="sm"
                class="join-item"
                phx-click="instances_next_page"
                disabled={@page >= @total_pages}
              >
                Next
              </.button>
            </div>
          </div>
        <% end %>
      </:body>
    </.card>
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
      <div class="modal-box modal-surface max-w-2xl">
        <div class="flex items-start gap-3">
          <div class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-info/10 text-info">
            <.icon name="hero-cog-6-tooth" class="h-5 w-5" />
          </div>

          <div class="min-w-0">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              MRF Policies
            </div>

            <h3 class="mt-1 truncate text-lg font-semibold tracking-tight">
              ActivityPub MRF Policies for <span class="font-mono">{@instance.domain}</span>
            </h3>
          </div>
        </div>

        <form phx-submit="save_policies" phx-change="sync_policy_form" class="mt-5">
          <div class="space-y-4">
            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <h4 class="text-2xs font-semibold uppercase tracking-[0.18em] text-error">
                Blocking
              </h4>
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

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <h4 class="text-2xs font-semibold uppercase tracking-[0.18em] text-warning">
                Visibility Restrictions
              </h4>
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

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <h4 class="text-2xs font-semibold uppercase tracking-[0.18em] text-info">
                Media Handling
              </h4>
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

            <div class="rounded-box border border-base-content/10 bg-base-200/35 p-4">
              <h4 class="text-2xs font-semibold uppercase tracking-[0.18em] text-secondary">
                Moderation
              </h4>
              <.policy_toggle
                field="report_removal"
                label="Reject Reports"
                description="Ignore Flag (report) activities from this instance"
                value={@policy_form["report_removal"]}
              />
            </div>
          </div>

          <div class="mt-5">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Reason (public)
            </label>
            <input
              type="text"
              name="reason"
              value={@policy_form["reason"]}
              class="input input-bordered mt-2 w-full"
              placeholder="Reason shown in transparency reports"
            />
          </div>

          <div class="mt-4">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Notes (private)
            </label>
            <textarea
              name="notes"
              class="textarea textarea-bordered mt-2 w-full"
              rows="2"
              placeholder="Internal notes for admins"
            >{@policy_form["notes"]}</textarea>
          </div>

          <div class="modal-action">
            <.button type="button" variant="default" phx-click="close_modal">
              Cancel
            </.button>
            <.button type="submit">
              Save Policies
            </.button>
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
    <label class="flex cursor-pointer items-start gap-3 py-2">
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
        <div class="text-xs text-base-content/60">{@description}</div>
      </div>
    </label>
    """
  end

  defp add_instance_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box modal-surface max-w-2xl">
        <div class="flex items-start gap-3">
          <div class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-info/10 text-info">
            <.icon name="hero-plus" class="h-5 w-5" />
          </div>

          <div>
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              New Policy
            </div>

            <h3 class="mt-1 text-lg font-semibold tracking-tight">
              Add ActivityPub Instance Policy
            </h3>
          </div>
        </div>

        <form phx-submit="add_instance" phx-change="sync_policy_form" class="mt-5">
          <div class="mb-4">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Domain
            </label>
            <input
              type="text"
              name="domain"
              value={@policy_form["domain"] || ""}
              placeholder="example.com or *.example.com"
              class="input input-bordered mt-2 w-full font-mono"
              required
              autofocus
            />
            <p class="mt-2 text-xs text-base-content/60">
              Use *.domain.com to match all subdomains
            </p>
          </div>

          <div class="mb-4">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Quick Presets
            </label>
            <div class="mt-2 flex flex-wrap gap-2">
              <.button
                type="button"
                variant="error"
                size="xs"
                phx-click="update_policy_form"
                phx-value-field="blocked"
                phx-value-value="true"
              >
                Block
              </.button>
              <.button
                type="button"
                variant="warning"
                size="xs"
                phx-click="update_policy_form"
                phx-value-field="federated_timeline_removal"
                phx-value-value="true"
              >
                Hide from FTL
              </.button>
              <.button
                type="button"
                variant="info"
                size="xs"
                phx-click="update_policy_form"
                phx-value-field="media_nsfw"
                phx-value-value="true"
              >
                Force NSFW
              </.button>
            </div>
          </div>

          <div class="max-h-64 space-y-2 overflow-y-auto rounded-box border border-base-content/10 bg-base-200/35 p-4">
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

          <div class="mt-4">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Reason (public)
            </label>
            <input
              type="text"
              name="reason"
              value={@policy_form["reason"] || ""}
              class="input input-bordered mt-2 w-full"
              placeholder="Spam, harassment, illegal content, etc."
            />
          </div>

          <div class="mt-4">
            <label class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Notes (private)
            </label>
            <textarea
              name="notes"
              class="textarea textarea-bordered mt-2 w-full"
              rows="2"
              placeholder="Internal notes"
            >{@policy_form["notes"] || ""}</textarea>
          </div>

          <div class="modal-action">
            <.button type="button" variant="default" phx-click="close_modal">
              Cancel
            </.button>
            <.button type="submit">
              Add Instance
            </.button>
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
    <.card class="panel-card" body_class="p-0">
      <:body>
        <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
          <div class="flex items-center justify-between gap-4">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Directory
              </div>

              <h2 class="mt-1 text-xl font-semibold tracking-tight">Remote Actors</h2>
            </div>

            <div class="badge badge-ghost badge-sm">{@total_count}</div>
          </div>
        </div>

        <div class="px-5 py-5 sm:px-6">
          <%= if length(@actors) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table table-sm w-full">
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
                          <%= if avatar_url =
                              ElektrineWeb.HtmlHelpers.safe_external_image_url(actor.avatar_url) do %>
                            <img
                              src={avatar_url}
                              class="h-8 w-8 rounded-full object-cover"
                              alt=""
                            />
                          <% else %>
                            <div class="flex h-8 w-8 items-center justify-center rounded-full bg-base-200">
                              <.icon name="hero-user" class="h-4 w-4 text-base-content/40" />
                            </div>
                          <% end %>
                          <div class="min-w-0">
                            <div class="text-sm font-medium">
                              {raw(ElektrineWeb.HtmlHelpers.render_actor_display_name(actor))}
                            </div>
                            <div class="truncate text-xs text-base-content/50 sm:hidden">
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
                      <td class="hidden text-xs text-base-content/60 md:table-cell">
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
            <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-10 text-center">
              <.icon name="hero-users" class="mx-auto h-10 w-10 text-base-content/25" />

              <p class="mt-3 text-sm text-base-content/60">No remote actors found</p>

              <p class="mt-1 text-sm text-base-content/45">
                Remote actors will appear here as they interact with your instance
              </p>
            </div>
          <% end %>
        </div>

        <%= if @total_pages > 1 do %>
          <div class="flex items-center justify-between border-t border-base-content/10 px-5 py-4 sm:px-6">
            <span class="text-xs text-base-content/60">Page {@page} of {@total_pages}</span>
            <div class="join">
              <.button
                variant="default"
                size="sm"
                class="join-item"
                phx-click="actors_prev_page"
                disabled={@page <= 1}
              >
                Previous
              </.button>
              <.button
                variant="default"
                size="sm"
                class="join-item"
                phx-click="actors_next_page"
                disabled={@page >= @total_pages}
              >
                Next
              </.button>
            </div>
          </div>
        <% end %>
      </:body>
    </.card>
    """
  end

  defp domains_table(assigns) do
    ~H"""
    <.card class="panel-card" body_class="p-0">
      <:body>
        <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Reach
          </div>

          <h2 class="mt-1 text-xl font-semibold tracking-tight">Top Domains by Actor Count</h2>
        </div>

        <div class="px-5 py-5 sm:px-6">
          <%= if length(@domain_stats) > 0 do %>
            <div class="space-y-3">
              <%= for {domain, count} <- @domain_stats do %>
                <div class="flex items-center gap-3 rounded-box border border-base-content/10 bg-base-200/45 px-4 py-3">
                  <div class="min-w-0 flex-1">
                    <div class="mb-1 flex items-center justify-between gap-3">
                      <span class="truncate font-mono text-sm">{domain}</span>
                      <span class="shrink-0 text-sm font-medium">{count} actors</span>
                    </div>
                    <progress
                      class="progress progress-primary w-full"
                      value={count}
                      max={elem(List.first(@domain_stats), 1)}
                    >
                    </progress>
                  </div>
                  <.button
                    variant="ghost"
                    size="xs"
                    phx-click="quick_block"
                    phx-value-domain={domain}
                    data-confirm="Block all activity from #{domain}?"
                    title="Quick Block"
                  >
                    <.icon name="hero-no-symbol" class="h-3 w-3 text-error" />
                  </.button>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-10 text-center">
              <.icon name="hero-chart-bar" class="mx-auto h-10 w-10 text-base-content/25" />

              <p class="mt-3 text-sm text-base-content/60">No domain statistics available</p>
            </div>
          <% end %>
        </div>
      </:body>
    </.card>
    """
  end

  defp activity_table(assigns) do
    ~H"""
    <.card class="panel-card" body_class="p-0">
      <:body>
        <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
          <div class="flex items-center justify-between gap-4">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Traffic
              </div>

              <h2 class="mt-1 text-xl font-semibold tracking-tight">Recent Activity</h2>
            </div>

            <div class="badge badge-ghost badge-sm">{length(@activities)}</div>
          </div>
        </div>

        <div class="px-5 py-5 sm:px-6">
          <%= if length(@activities) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table table-sm w-full">
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
                        <span class="block max-w-[200px] truncate font-mono text-xs">
                          {activity.actor_uri}
                        </span>
                      </td>
                      <td class="hidden md:table-cell">
                        <span class="block max-w-[200px] truncate font-mono text-xs text-base-content/60">
                          {activity.object_id || "-"}
                        </span>
                      </td>
                      <td class="text-xs text-base-content/60">
                        {Calendar.strftime(activity.inserted_at, "%m-%d %H:%M")}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-10 text-center">
              <.icon name="hero-bolt" class="mx-auto h-10 w-10 text-base-content/25" />

              <p class="mt-3 text-sm text-base-content/60">No recent activity</p>

              <p class="mt-1 text-sm text-base-content/45">Federation activity will appear here</p>
            </div>
          <% end %>
        </div>
      </:body>
    </.card>
    """
  end
end
