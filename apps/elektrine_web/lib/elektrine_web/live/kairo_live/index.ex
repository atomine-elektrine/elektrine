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

  def handle_event("select_source", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_id, parse_id(id)) |> assign_view()}
  end

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
            Browse your durable knowledge. Sources are ingested via the <.link
              navigate={~p"/account?tab=developer"}
              class="link"
            >API</.link>.
          </p>
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
              <form phx-change="search" phx-submit="search">
                <input
                  type="text"
                  name="query"
                  value={@query}
                  placeholder="Search sources…"
                  autocomplete="off"
                  phx-debounce="150"
                  class="input input-bordered input-sm w-full"
                />
              </form>

              <div
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
                  No sources yet. Ingest via the API to get started.
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

          <%!-- Reader --%>
          <section class="card panel-card border border-base-300 lg:max-h-[calc(100vh-11rem)] lg:overflow-y-auto">
            <div
              :if={is_nil(@selected)}
              class="flex flex-col items-center justify-center gap-2 p-12 text-center text-base-content/50"
            >
              <.icon name="hero-document-magnifying-glass" class="h-10 w-10" />
              <p class="text-sm">Select a source to read it here.</p>
            </div>

            <article :if={@selected} class="card-body space-y-4 p-4 sm:p-6">
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
