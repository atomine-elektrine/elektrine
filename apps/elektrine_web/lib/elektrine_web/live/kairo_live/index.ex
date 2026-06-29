defmodule ElektrineWeb.KairoLive.Index do
  use ElektrineWeb, :live_view

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
    |> assign(:project_form, to_form(%{"name" => "", "description" => ""}, as: :project))
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
          <section class="card panel-card border border-base-300">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-2 text-base sm:text-lg">Ingest via API</h2>
              <p class="text-sm text-base-content/70">
                Sources are ingested through the Kairo API, not this page. Send a
                <code class="rounded bg-base-300 px-1 py-0.5 text-xs">POST</code>
                to
                <code class="rounded bg-base-300 px-1 py-0.5 text-xs">/api/ext/v1/kairo/sources</code>
                with a personal access token that has the
                <code class="rounded bg-base-300 px-1 py-0.5 text-xs">write:kairo</code>
                scope. Encrypt the content client-side before sending to keep it zero-knowledge.
              </p>
              <div class="mt-3">
                <.link navigate={~p"/account?tab=developer"} class="btn btn-outline btn-sm">
                  Manage API tokens
                </.link>
              </div>
            </div>
          </section>

          <div
            id="kairo-vault"
            phx-hook="KairoVault"
            class="contents"
            data-kairo-master-configured={to_string(@master_vault_configured)}
            data-kairo-master-wrapped-dek={
              @master_vault_wrapped_dek && Jason.encode!(@master_vault_wrapped_dek)
            }
          >
            <section class="card panel-card overflow-hidden border border-base-300">
              <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                <h2 class="card-title text-base sm:text-lg">Recent sources</h2>
                <div class="hidden items-center gap-2" data-kairo-locked-hint>
                  <%= if @master_vault_configured do %>
                    <input
                      type="password"
                      class="input input-bordered input-xs w-40"
                      placeholder="Master passphrase"
                      autocomplete="current-password"
                      data-kairo-master-unlock-input
                    />
                    <button type="button" class="btn btn-outline btn-xs" data-kairo-master-unlock>
                      Unlock to decrypt
                    </button>
                    <span class="hidden text-xs text-error" data-kairo-master-error></span>
                  <% else %>
                    <span class="text-xs text-warning">
                      <.link navigate={~p"/account/master-password"} class="link">
                        Set up master password
                      </.link>
                      to decrypt
                    </span>
                  <% end %>
                </div>
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
