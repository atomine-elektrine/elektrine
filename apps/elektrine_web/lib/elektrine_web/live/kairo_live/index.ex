defmodule ElektrineWeb.KairoLive.Index do
  use ElektrineWeb, :live_view

  alias Kairo.Source

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

      user ->
        {:ok, load_kairo(socket, user)}
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

  def handle_event("create_source", %{"source" => params}, socket) do
    user = socket.assigns.current_user

    case Kairo.create_source(user, params) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Source ingested")
         |> load_kairo(user)}

      {:error, :project_not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Source could not be ingested")}
    end
  end

  defp load_kairo(socket, user) do
    projects = Kairo.list_projects(user)
    sources = Kairo.list_sources(user, limit: 25)
    master = Elektrine.Vault.get(user.id)

    socket
    |> assign(:page_title, "Kairo")
    |> assign(:projects, projects)
    |> assign(:sources, sources)
    |> assign(:master_vault_configured, not is_nil(master))
    |> assign(:master_vault_wrapped_dek, master && master.wrapped_dek)
    |> assign(:source_types, Source.source_types())
    |> assign(:project_form, to_form(%{"name" => "", "description" => ""}, as: :project))
    |> assign(:source_form, to_form(default_source_params(projects), as: :source))
  end

  defp default_source_params(projects) do
    %{
      "project_id" => projects |> List.first() |> then(&if &1, do: &1.id, else: ""),
      "source_type" => "url",
      "title" => "",
      "url" => "",
      "content" => "",
      "content_format" => "markdown",
      "tags" => ""
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="kairo" current_user={@current_user} class="mb-6 sm:mb-8" />

      <div class="mb-6 flex flex-col gap-3 sm:mb-8 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold text-base-content sm:text-3xl">Kairo</h1>
          <p class="mt-2 text-base-content/70">
            Personal data OS — ingest, compile, and query durable knowledge.
          </p>
        </div>
        <div class="stats stats-horizontal border border-base-300 bg-base-200 shadow-none">
          <div class="stat px-4 py-3">
            <div class="stat-title text-xs">Sources</div>
            <div class="stat-value text-2xl">{length(@sources)}</div>
          </div>
          <div class="stat px-4 py-3">
            <div class="stat-title text-xs">Projects</div>
            <div class="stat-value text-2xl">{length(@projects)}</div>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-8">
        <main class="space-y-6">
          <div
            id="kairo-vault"
            phx-hook="KairoVault"
            class="contents"
            data-kairo-master-configured={to_string(@master_vault_configured)}
            data-kairo-master-wrapped-dek={
              @master_vault_wrapped_dek && Jason.encode!(@master_vault_wrapped_dek)
            }
          >
            <section class="card panel-card border border-base-300">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-base sm:text-lg">Ingest</h2>
                <.form
                  for={@source_form}
                  phx-submit="create_source"
                  id="kairo-source-form"
                  class="space-y-4"
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <.input
                      field={@source_form[:source_type]}
                      type="select"
                      label="Type"
                      options={Enum.map(@source_types, &{String.replace(&1, "_", " "), &1})}
                    />
                    <.input
                      field={@source_form[:project_id]}
                      type="select"
                      label="Project"
                      prompt="Inbox"
                      options={Enum.map(@projects, &{&1.name, &1.id})}
                    />
                  </div>

                  <div class="grid gap-4 md:grid-cols-2">
                    <.input field={@source_form[:title]} label="Title" />
                    <.input field={@source_form[:url]} type="url" label="URL" />
                  </div>

                  <.input field={@source_form[:content]} type="textarea" label="Content" rows="8" />

                  <div class="grid gap-4 md:grid-cols-2">
                    <.input field={@source_form[:content_format]} label="Format" />
                    <.input field={@source_form[:tags]} label="Tags" />
                  </div>

                  <label class="flex items-center gap-2 text-sm">
                    <input type="checkbox" class="checkbox checkbox-sm" data-kairo-encrypt-toggle />
                    <span>
                      🔒 Encrypt (zero-knowledge) — store the content so only you can read it
                    </span>
                  </label>
                  <div
                    class="hidden space-y-2 rounded border border-warning/40 bg-warning/5 p-3"
                    data-kairo-locked-hint
                  >
                    <%= if @master_vault_configured do %>
                      <p class="text-xs text-base-content/70">
                        Enter your master passphrase once to encrypt in this tab.
                      </p>
                      <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
                        <input
                          type="password"
                          class="input input-bordered input-sm w-full sm:w-64"
                          placeholder="Master passphrase"
                          autocomplete="current-password"
                          data-kairo-master-unlock-input
                        />
                        <button type="button" class="btn btn-outline btn-sm" data-kairo-master-unlock>
                          Unlock
                        </button>
                      </div>
                      <p class="hidden text-xs text-error" data-kairo-master-error></p>
                    <% else %>
                      <p class="text-xs text-warning">
                        Set up your
                        <.link navigate={~p"/account/master-password"} class="link">
                          master password
                        </.link>
                        to encrypt.
                      </p>
                    <% end %>
                  </div>

                  <input
                    type="hidden"
                    name="source[encrypted]"
                    value="false"
                    data-kairo-encrypted-flag
                  />
                  <input type="hidden" name="source[encrypted_content]" data-kairo-encrypted-content />

                  <div class="flex justify-end">
                    <button type="button" class="btn btn-primary" data-kairo-submit>Ingest</button>
                  </div>
                </.form>
              </div>
            </section>

            <section class="card panel-card overflow-hidden border border-base-300">
              <div class="border-b border-base-300 px-4 py-3 sm:px-6">
                <h2 class="card-title text-base sm:text-lg">Recent sources</h2>
              </div>
              <div class="divide-y divide-base-300">
                <div :if={@sources == []} class="px-4 py-8 text-sm text-base-content/60">
                  No sources yet.
                </div>
                <article :for={source <- @sources} class="px-4 py-4">
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div class="min-w-0">
                      <h3 class="truncate font-medium">
                        {source.title || source.url || source.source_type}
                      </h3>
                      <p class="truncate text-sm text-base-content/60">{source.url}</p>
                    </div>
                    <div class="flex shrink-0 gap-2">
                      <span :if={source.encrypted} class="badge badge-warning badge-outline">
                        🔒
                      </span>
                      <span class="badge badge-outline">{source.source_type}</span>
                      <span class="badge">{source.status}</span>
                    </div>
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2 text-xs text-base-content/60">
                    <span>{format_datetime(source.ingested_at)}</span>
                    <span :if={source.project}>{source.project.name}</span>
                    <span :for={tag <- source.tags || []} class="badge badge-ghost badge-sm">
                      {tag}
                    </span>
                  </div>
                  <div :if={source.encrypted} class="mt-2">
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      data-kairo-decrypt
                      data-kairo-payload={Jason.encode!(source.encrypted_content)}
                    >
                      🔒 Decrypt
                    </button>
                    <pre
                      class="mt-1 hidden whitespace-pre-wrap break-words rounded bg-base-200 p-2 text-xs"
                      data-kairo-output
                    ></pre>
                  </div>
                </article>
              </div>
            </section>
          </div>
        </main>

        <aside class="space-y-4 sm:space-y-6">
          <section class="card panel-card border border-base-300">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-base sm:text-lg">New project</h2>
              <.form for={@project_form} phx-submit="create_project" class="space-y-4">
                <.input field={@project_form[:name]} label="Name" required />
                <.input
                  field={@project_form[:description]}
                  type="textarea"
                  label="Description"
                  rows="4"
                />
                <button type="submit" class="btn btn-secondary w-full">Create</button>
              </.form>
            </div>
          </section>

          <section class="card panel-card overflow-hidden border border-base-300">
            <div class="border-b border-base-300 px-4 py-3 sm:px-6">
              <h2 class="card-title text-base sm:text-lg">Projects</h2>
            </div>
            <div class="divide-y divide-base-300">
              <div :if={@projects == []} class="px-4 py-6 text-sm text-base-content/60">
                Inbox only.
              </div>
              <div :for={project <- @projects} class="px-4 py-3">
                <div class="font-medium">{project.name}</div>
                <div class="text-sm text-base-content/60">{project.slug}</div>
              </div>
            </div>
          </section>
        </aside>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "not ingested"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
