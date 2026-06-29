defmodule ElektrineWeb.KairoLive.Index do
  use ElektrineWeb, :live_view

  @source_limit 200

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

      user ->
        {:ok,
         socket
         |> assign(:query, "")
         |> assign(:active_tag, nil)
         |> assign(:active_project, nil)
         |> assign(:selected_id, nil)
         |> assign(:view_mode, "reader")
         |> assign(:composing, false)
         |> assign(:compose, empty_compose())
         |> assign(:compose_tab, "write")
         |> load_kairo(user)}
    end
  end

  @impl true
  def handle_event("create_project", %{"project" => params}, socket) do
    user = socket.assigns.current_user

    case Kairo.create_project(user, params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> load_kairo(user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Project could not be created")}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign_view()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:query, "") |> assign_view()}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    active = if socket.assigns.active_tag == tag, do: nil, else: tag
    {:noreply, socket |> assign(:active_tag, active) |> assign_view()}
  end

  def handle_event("filter_project", %{"project" => project}, socket) do
    value = parse_project_filter(project)
    active = if socket.assigns.active_project == value, do: nil, else: value
    {:noreply, socket |> assign(:active_project, active) |> assign_view()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:active_tag, nil)
     |> assign(:active_project, nil)
     |> assign_view()}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) when mode in ~w(reader graph) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("select_source", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:composing, false)
     |> assign(:view_mode, "reader")
     |> assign(:selected_id, parse_id(id))
     |> assign_view()}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, "reader")
     |> assign(:composing, true)
     |> assign(:selected, nil)
     |> assign(:selected_id, nil)
     |> assign(:compose, empty_compose())
     |> assign(:compose_tab, "write")}
  end

  def handle_event("cancel_note", _params, socket) do
    {:noreply, assign(socket, :composing, false)}
  end

  def handle_event("set_compose_tab", %{"tab" => tab}, socket) when tab in ~w(write preview) do
    {:noreply, assign(socket, :compose_tab, tab)}
  end

  def handle_event("compose_change", %{"note" => note}, socket) do
    {:noreply, assign(socket, :compose, Map.merge(empty_compose(), note))}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "source_type" => "markdown",
      "content_format" => "markdown",
      "title" => note["title"],
      "content" => note["content"],
      "tags" => note["tags"],
      "project_id" => blank_to_nil(note["project_id"])
    }

    case Kairo.create_source(user, attrs) do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(:composing, false)
         |> assign(:selected_id, source.id)
         |> put_flash(:info, "Note saved")
         |> load_kairo(user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Add a title or some content first.")}
    end
  end

  defp empty_compose, do: %{"title" => "", "content" => "", "project_id" => "", "tags" => ""}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_project_filter("inbox"), do: :inbox
  defp parse_project_filter(id), do: parse_id(id)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp load_kairo(socket, user) do
    socket
    |> assign(:page_title, "Kairo")
    |> assign(:projects, Kairo.list_projects(user))
    |> assign(:sources, Kairo.list_sources(user, limit: @source_limit))
    |> assign(:master_vault, Elektrine.Vault.get(user.id))
    |> assign(:project_form, to_form(%{"name" => "", "description" => ""}, as: :project))
    |> assign_view()
  end

  # Derives the filtered explorer view from the current sources/query/tag/selection.
  defp assign_view(socket) do
    %{
      sources: sources,
      query: query,
      active_tag: active_tag,
      active_project: active_project,
      selected_id: selected_id
    } = socket.assigns

    visible = visible_sources(sources, query, active_tag, active_project)
    selected = Enum.find(sources, &(&1.id == selected_id))

    socket
    |> assign(:all_tags, all_tags(sources))
    |> assign(:folders, folders(visible, socket.assigns.projects))
    |> assign(:visible_count, length(visible))
    |> assign(:selected, selected)
    |> assign(:related, related_sources(sources, selected))
    |> assign(:has_encrypted_sources, Enum.any?(sources, & &1.encrypted))
    |> assign(:graph, build_graph(visible, socket.assigns.projects))
  end

  # Palette for project-colored source nodes. Inbox (no project) falls back to a
  # neutral gray. Mid-tone hues so they read on both light and dark themes.
  @project_palette ~w(#6366f1 #ec4899 #14b8a6 #f59e0b #8b5cf6 #ef4444 #10b981 #3b82f6)
  @inbox_color "#9ca3af"

  # Cap on how many of its strongest neighbors each source links to. Keeps the
  # graph sparse and readable (and cheap to animate) even when many sources share
  # a common tag, which would otherwise produce a near-complete graph.
  @max_edges_per_source 5

  # Graph: one node per source (file), with an edge between two
  # sources that share tags. Edge weight is the number of shared tags. To avoid a
  # hairball, each source only links to its strongest few neighbors. Sources are
  # colored by project; untagged or unconnected sources appear as lone nodes.
  defp build_graph(sources, projects) do
    colors = project_colors(projects)

    nodes =
      Enum.map(sources, fn source ->
        %{
          id: "s-#{source.id}",
          ref: source.id,
          label: source_label(source),
          color: Map.get(colors, source.project_id, @inbox_color)
        }
      end)

    tagged =
      sources
      |> Enum.map(fn source -> {source.id, MapSet.new(source.tags || [])} end)
      |> Enum.reject(fn {_id, tags} -> MapSet.size(tags) == 0 end)

    pairs =
      for {id_a, tags_a} <- tagged,
          {id_b, tags_b} <- tagged,
          id_a < id_b,
          shared = MapSet.size(MapSet.intersection(tags_a, tags_b)),
          shared > 0 do
        {id_a, id_b, shared}
      end

    edges =
      pairs
      |> strongest_edges(@max_edges_per_source)
      |> Enum.map(fn {id_a, id_b, weight} ->
        %{source: "s-#{id_a}", target: "s-#{id_b}", weight: weight}
      end)

    %{nodes: nodes, edges: edges}
  end

  # Keeps, for each source, only its `max` highest-weight pairs, then unions
  # those choices so an edge survives if either endpoint ranks it.
  defp strongest_edges(pairs, max) do
    pairs
    |> Enum.reduce(%{}, fn {a, b, _w} = pair, acc ->
      acc
      |> Map.update(a, [pair], &[pair | &1])
      |> Map.update(b, [pair], &[pair | &1])
    end)
    |> Enum.flat_map(fn {_id, node_pairs} ->
      node_pairs
      |> Enum.sort_by(fn {_a, _b, w} -> -w end)
      |> Enum.take(max)
    end)
    |> Enum.uniq()
  end

  defp project_colors(projects) do
    projects
    |> Enum.with_index()
    |> Map.new(fn {project, index} ->
      {project.id, Enum.at(@project_palette, rem(index, length(@project_palette)))}
    end)
  end

  defp visible_sources(sources, query, active_tag, active_project) do
    Enum.filter(
      sources,
      &(project_match?(&1, active_project) and tag_match?(&1, active_tag) and
          query_match?(&1, query))
    )
  end

  defp project_match?(_source, nil), do: true
  defp project_match?(source, :inbox), do: is_nil(source.project_id)
  defp project_match?(source, project_id), do: source.project_id == project_id

  defp tag_match?(_source, nil), do: true
  defp tag_match?(source, tag), do: tag in (source.tags || [])

  defp query_match?(_source, ""), do: true
  defp query_match?(_source, nil), do: true

  defp query_match?(source, query) do
    needle = String.downcase(String.trim(query))

    [source.title, source.url, source.source_type | source.tags || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  defp folders(visible, projects) do
    by_project = Enum.group_by(visible, & &1.project_id)

    project_folders =
      projects
      |> Enum.map(fn project ->
        %{id: project.id, name: project.name, sources: Map.get(by_project, project.id, [])}
      end)
      |> Enum.reject(&(&1.sources == []))

    inbox = Map.get(by_project, nil, [])

    if inbox == [],
      do: project_folders,
      else: [%{id: nil, name: "Inbox", sources: inbox} | project_folders]
  end

  defp all_tags(sources) do
    sources
    |> Enum.flat_map(&(&1.tags || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp related_sources(_sources, nil), do: []

  defp related_sources(sources, %{tags: tags} = selected) when is_list(tags) and tags != [] do
    tag_set = MapSet.new(tags)

    sources
    |> Enum.reject(&(&1.id == selected.id))
    |> Enum.filter(fn source ->
      Enum.any?(source.tags || [], &MapSet.member?(tag_set, &1))
    end)
    |> Enum.take(8)
  end

  defp related_sources(_sources, _selected), do: []

  defp source_label(source) do
    cond do
      present?(source.title) -> source.title
      present?(source.url) -> source.url
      true -> "Untitled #{String.replace(source.source_type || "source", "_", " ")}"
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_datetime(nil), do: "not ingested"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="kairo" current_user={@current_user} class="mb-6 sm:mb-8" />

      <div class="mb-4 flex flex-col gap-3 sm:mb-6 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold text-base-content sm:text-3xl">Kairo</h1>
          <p class="mt-1 text-base-content/70">
            Browse your durable knowledge. Sources are ingested via the
            <.link
              navigate={~p"/account?tab=developer"}
              class="link"
            >
              API
            </.link>
            and encrypted at rest; flag a source <code>encrypted</code>
            for
            zero-knowledge.
          </p>
        </div>
        <div class="flex items-center gap-3">
          <div class="join">
            <button
              type="button"
              phx-click="toggle_view"
              phx-value-mode="reader"
              class={["btn btn-sm join-item", @view_mode == "reader" && "btn-active"]}
            >
              <.icon name="hero-list-bullet" class="h-4 w-4" /> List
            </button>
            <button
              type="button"
              phx-click="toggle_view"
              phx-value-mode="graph"
              class={["btn btn-sm join-item", @view_mode == "graph" && "btn-active"]}
            >
              <.icon name="hero-share" class="h-4 w-4" /> Graph
            </button>
          </div>
          <div class="stats stats-horizontal border border-base-300 bg-base-200 shadow-none">
            <div class="stat px-4 py-2">
              <div class="stat-title text-xs">Sources</div>
              <div class="stat-value text-xl">{length(@sources)}</div>
            </div>
            <div class="stat px-4 py-2">
              <div class="stat-title text-xs">Projects</div>
              <div class="stat-value text-xl">{length(@projects)}</div>
            </div>
          </div>
        </div>
      </div>

      <div
        id="kairo-vault"
        phx-hook="KairoVault"
        data-kairo-master-configured={to_string(not is_nil(@master_vault))}
        data-kairo-master-wrapped-dek={@master_vault && Jason.encode!(@master_vault.wrapped_dek)}
      >
        <div class="grid grid-cols-1 gap-4 lg:grid-cols-[18rem_minmax(0,1fr)] lg:gap-6">
          <%!-- Explorer --%>
          <aside class="card panel-card flex flex-col overflow-hidden border border-base-300 lg:max-h-[calc(100vh-11rem)]">
            <div class="space-y-2 border-b border-base-300 p-3">
              <button type="button" phx-click="new_note" class="btn btn-primary btn-sm w-full">
                <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
              </button>

              <form id="kairo-search-form" phx-change="search" phx-submit="search" class="relative">
                <input
                  id="kairo-search"
                  type="text"
                  name="query"
                  value={@query}
                  placeholder="Search sources…"
                  autocomplete="off"
                  phx-debounce="150"
                  class="input input-bordered input-sm w-full pr-8"
                />
                <button
                  :if={@query != ""}
                  type="button"
                  phx-click="clear_search"
                  aria-label="Clear search"
                  class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/50 hover:text-base-content"
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </button>
              </form>

              <div
                :if={@has_encrypted_sources}
                class="hidden flex-col gap-2 rounded-lg border border-warning/30 bg-warning/5 p-2"
                data-kairo-locked-hint
              >
                <%= if @master_vault do %>
                  <input
                    type="password"
                    class="input input-bordered input-xs w-full"
                    placeholder="Master passphrase"
                    autocomplete="current-password"
                    data-kairo-master-unlock-input
                  />
                  <button
                    type="button"
                    class="btn btn-outline btn-xs w-full"
                    data-kairo-master-unlock
                  >
                    Unlock to decrypt
                  </button>
                <% else %>
                  <span class="text-xs text-warning">
                    <.link navigate={~p"/account/master-password"} class="link">
                      Set up master password
                    </.link>
                    to decrypt
                  </span>
                <% end %>
              </div>
              <p class="hidden text-xs text-error" data-kairo-master-error></p>

              <div :if={@projects != []} class="space-y-1">
                <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/50">
                  Projects
                </p>
                <div class="flex flex-wrap gap-1">
                  <button
                    :for={project <- @projects}
                    type="button"
                    phx-click="filter_project"
                    phx-value-project={project.id}
                    class={[
                      "badge badge-sm cursor-pointer gap-1",
                      if(@active_project == project.id, do: "badge-primary", else: "badge-outline")
                    ]}
                  >
                    <.icon name="hero-folder" class="h-3 w-3" /> {project.name}
                  </button>
                  <button
                    :if={Enum.any?(@sources, &is_nil(&1.project_id))}
                    type="button"
                    phx-click="filter_project"
                    phx-value-project="inbox"
                    class={[
                      "badge badge-sm cursor-pointer gap-1",
                      if(@active_project == :inbox, do: "badge-primary", else: "badge-outline")
                    ]}
                  >
                    <.icon name="hero-inbox" class="h-3 w-3" /> Inbox
                  </button>
                </div>
              </div>

              <div :if={@all_tags != []} class="space-y-1">
                <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/50">
                  Tags
                </p>
                <div class="flex flex-wrap gap-1">
                  <button
                    :for={tag <- @all_tags}
                    type="button"
                    phx-click="filter_tag"
                    phx-value-tag={tag}
                    class={[
                      "badge badge-sm cursor-pointer",
                      if(@active_tag == tag, do: "badge-primary", else: "badge-ghost")
                    ]}
                  >
                    #{tag}
                  </button>
                </div>
              </div>
            </div>

            <nav class="flex-1 space-y-1 overflow-y-auto p-2">
              <p :if={@visible_count == 0} class="px-2 py-4 text-sm text-base-content/60">
                <%= if @sources == [] do %>
                  No sources yet. Start a new note or ingest via the API.
                <% else %>
                  No matching sources.
                <% end %>
              </p>

              <details :for={folder <- @folders} open class="group">
                <summary class="flex cursor-pointer items-center justify-between rounded px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/60 hover:bg-base-300/40">
                  <span class="flex items-center gap-1">
                    <.icon
                      name="hero-chevron-right"
                      class="h-3 w-3 transition-transform group-open:rotate-90"
                    /> {folder.name}
                  </span>
                  <span class="opacity-60">{length(folder.sources)}</span>
                </summary>
                <ul class="mt-1 space-y-0.5">
                  <li :for={source <- folder.sources}>
                    <button
                      type="button"
                      phx-click="select_source"
                      phx-value-id={source.id}
                      class={[
                        "flex w-full items-center gap-1.5 truncate rounded px-2 py-1.5 text-left text-sm",
                        if(@selected && @selected.id == source.id,
                          do: "bg-primary/15 text-primary",
                          else: "hover:bg-base-300/40"
                        )
                      ]}
                    >
                      <span :if={source.encrypted} title="Encrypted">🔒</span>
                      <.icon
                        :if={!source.encrypted}
                        name="hero-document-text"
                        class="h-4 w-4 shrink-0"
                      />
                      <span class="truncate">{source_label(source)}</span>
                    </button>
                  </li>
                </ul>
              </details>
            </nav>

            <div class="border-t border-base-300 p-2">
              <details class="group">
                <summary class="flex cursor-pointer items-center gap-1 rounded px-2 py-1 text-xs text-base-content/70 hover:bg-base-300/40">
                  <.icon name="hero-plus" class="h-3.5 w-3.5" /> New project
                </summary>
                <.form for={@project_form} phx-submit="create_project" class="mt-2 space-y-2 px-1">
                  <.input field={@project_form[:name]} placeholder="Name" required />
                  <.input field={@project_form[:description]} placeholder="Description (optional)" />
                  <button type="submit" class="btn btn-secondary btn-sm w-full">
                    Create project
                  </button>
                </.form>
              </details>
            </div>
          </aside>

          <%!-- Reader / editor --%>
          <section class="card panel-card border border-base-300 lg:max-h-[calc(100vh-11rem)] lg:overflow-y-auto">
            <%!-- Graph view --%>
            <div
              :if={@view_mode == "graph"}
              class="relative h-[60vh] text-base-content lg:h-[calc(100vh-11rem)]"
            >
              <div
                id="kairo-graph"
                phx-hook="KairoGraph"
                data-graph={Jason.encode!(@graph)}
                class="absolute inset-0"
              >
              </div>
              <div class="pointer-events-none absolute bottom-2 left-3 text-xs text-base-content/40">
                connected files share a tag · drag to reposition · scroll to zoom · click to open
              </div>
            </div>

            <form
              :if={@view_mode == "reader" and @composing}
              id="kairo-note-form"
              phx-submit="save_note"
              phx-change="compose_change"
              class="card-body space-y-3 p-4 sm:p-6"
            >
              <div class="flex items-center justify-between">
                <h2 class="card-title text-base sm:text-lg">New note</h2>
                <button type="button" phx-click="cancel_note" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
              </div>

              <input
                id="kairo-note-title"
                type="text"
                name="note[title]"
                value={@compose["title"]}
                placeholder="Title"
                autocomplete="off"
                class="input input-bordered w-full font-medium"
              />

              <div class="grid gap-2 sm:grid-cols-2">
                <select name="note[project_id]" class="select select-bordered select-sm">
                  <option value="" selected={@compose["project_id"] in [nil, ""]}>Inbox</option>
                  <option
                    :for={project <- @projects}
                    value={project.id}
                    selected={to_string(@compose["project_id"]) == to_string(project.id)}
                  >
                    {project.name}
                  </option>
                </select>
                <input
                  id="kairo-note-tags"
                  type="text"
                  name="note[tags]"
                  value={@compose["tags"]}
                  placeholder="tags, comma, separated"
                  autocomplete="off"
                  class="input input-bordered input-sm w-full"
                />
              </div>

              <div role="tablist" class="tabs tabs-bordered">
                <button
                  type="button"
                  phx-click="set_compose_tab"
                  phx-value-tab="write"
                  class={["tab", @compose_tab == "write" && "tab-active"]}
                >
                  Write
                </button>
                <button
                  type="button"
                  phx-click="set_compose_tab"
                  phx-value-tab="preview"
                  class={["tab", @compose_tab == "preview" && "tab-active"]}
                >
                  Preview
                </button>
              </div>

              <textarea
                :if={@compose_tab == "write"}
                id="kairo-note-content"
                name="note[content]"
                rows="16"
                phx-debounce="200"
                placeholder="Write markdown…"
                class="textarea textarea-bordered w-full font-mono text-sm"
              >{@compose["content"]}</textarea>
              <div
                :if={@compose_tab == "preview"}
                class="prose min-h-[16rem] max-w-none rounded border border-base-300 bg-base-100 p-3"
              >
                {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@compose["content"] || ""))}
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_note" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Save note</button>
              </div>
            </form>

            <div
              :if={@view_mode == "reader" and is_nil(@selected) and not @composing}
              class="flex flex-col items-center justify-center gap-3 p-12 text-center text-base-content/50"
            >
              <.icon name="hero-document-magnifying-glass" class="h-10 w-10" />
              <p class="text-sm">Select a source to read it, or start a new note.</p>
              <button type="button" phx-click="new_note" class="btn btn-outline btn-sm">
                <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
              </button>
            </div>

            <article
              :if={@view_mode == "reader" and @selected}
              class="card-body space-y-4 p-4 sm:p-6"
            >
              <header class="space-y-2 border-b border-base-300 pb-4">
                <h1 class="text-xl font-bold sm:text-2xl">{source_label(@selected)}</h1>
                <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
                  <span class="badge badge-outline badge-sm">{@selected.source_type}</span>
                  <span class="badge badge-sm">{@selected.status}</span>
                  <span :if={@selected.encrypted} class="badge badge-warning badge-outline badge-sm">
                    🔒 encrypted
                  </span>
                  <span :if={@selected.project}>· {@selected.project.name}</span>
                  <span>· {format_datetime(@selected.ingested_at)}</span>
                </div>
                <a
                  :if={present_url?(@selected.url)}
                  href={@selected.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="link link-primary inline-flex items-center gap-1 text-sm"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
                  {@selected.url}
                </a>
                <div :if={@selected.tags not in [nil, []]} class="flex flex-wrap gap-1">
                  <button
                    :for={tag <- @selected.tags}
                    type="button"
                    phx-click="filter_tag"
                    phx-value-tag={tag}
                    class="badge badge-ghost badge-sm cursor-pointer"
                  >
                    #{tag}
                  </button>
                </div>
              </header>

              <div
                :if={@selected.encrypted}
                class="space-y-3 rounded-lg border border-base-300 bg-base-200/40 p-4"
                data-kairo-reader
              >
                <p class="text-sm text-base-content/70">
                  This source is encrypted. Decrypt it in this tab to read the content.
                </p>
                <button
                  type="button"
                  class="btn btn-outline btn-sm"
                  data-kairo-decrypt
                  data-kairo-payload={Jason.encode!(@selected.encrypted_content)}
                >
                  🔒 Decrypt content
                </button>
                <pre
                  class="mt-1 hidden max-w-none whitespace-pre-wrap break-words rounded bg-base-100 p-3 text-sm"
                  data-kairo-output
                ></pre>
              </div>

              <div :if={!@selected.encrypted} class="prose max-w-none">
                {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@selected.content || ""))}
              </div>

              <div :if={@related != []} class="border-t border-base-300 pt-4">
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Related (shared tags)
                </h3>
                <ul class="space-y-1">
                  <li :for={source <- @related}>
                    <button
                      type="button"
                      phx-click="select_source"
                      phx-value-id={source.id}
                      class="flex w-full items-center gap-1.5 truncate rounded px-2 py-1 text-left text-sm hover:bg-base-300/40"
                    >
                      <span :if={source.encrypted}>🔒</span>
                      <.icon :if={!source.encrypted} name="hero-link" class="h-3.5 w-3.5 shrink-0" />
                      <span class="truncate">{source_label(source)}</span>
                    </button>
                  </li>
                </ul>
              </div>
            </article>
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp present_url?(url), do: is_binary(url) and String.trim(url) != ""
end
