defmodule ElektrineNerveWeb.NerveLive do
  @moduledoc """
  Dedicated Nerve management LiveView.
  """

  use ElektrineNerveWeb, :live_view

  alias Elektrine.Nerve
  alias Elektrine.Nerve.NerveEntry
  alias Elektrine.Nerve.Payloads
  alias ElektrineNerveWeb.Components.Platform.ENav

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    nerve_settings = Nerve.get_nerve_settings(user.id)
    nerve_configured = not is_nil(nerve_settings)
    active_announcements = Elektrine.Admin.list_active_announcements_for_user(user.id)

    entries =
      if nerve_configured,
        do: Nerve.list_entries(user.id),
        else: []

    {:ok,
     socket
     |> assign(:page_title, "Nerve")
     |> assign(:active_announcements, active_announcements)
     |> assign(:nerve_configured, nerve_configured)
     |> assign(:nerve_verifier, nerve_settings && nerve_settings.encrypted_verifier)
     |> assign(:entries, entries)
     |> assign(:form, entry_form(user.id))}
  end

  @impl true
  def handle_event("validate", %{"entry" => params}, socket) do
    user = socket.assigns.current_user
    {:noreply, assign(socket, :form, entry_form(user.id, params, :validate))}
  end

  @impl true
  def handle_event("create", %{"entry" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- Payloads.decode_encrypted_entry_params(params),
         {:ok, _entry} <- Nerve.create_entry(user.id, params) do
      {:noreply,
       socket
       |> assign(:entries, Nerve.list_entries(user.id))
       |> assign(:form, entry_form(user.id))
       |> put_flash(:info, "Nerve entry saved")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         put_flash(socket, :error, "Nerve payload is invalid. Unlock Nerve and try again.")}

      {:error, :nerve_not_configured} ->
        {:noreply,
         put_flash(socket, :error, "Set up your Nerve passphrase before saving entries.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(%{changeset | action: :insert}, as: :entry))}
    end
  end

  @impl true
  def handle_event("setup_nerve", %{"nerve" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- Payloads.decode_setup_params(params),
         {:ok, settings} <- Nerve.setup_nerve(user.id, params) do
      {:noreply,
       socket
       |> assign(:nerve_configured, true)
       |> assign(:nerve_verifier, settings.encrypted_verifier)
       |> assign(:entries, Nerve.list_entries(user.id))
       |> put_flash(:info, "Nerve configured")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Nerve setup payload is invalid. Use the setup form to continue."
         )}

      {:error, changeset} ->
        details =
          changeset.errors
          |> Keyword.keys()
          |> Enum.map_join(", ", &to_string/1)

        message =
          if details == "" do
            "Could not configure Nerve."
          else
            "Could not configure Nerve (#{details})."
          end

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, _entry} <- Nerve.delete_entry(user.id, entry_id) do
      {:noreply,
       socket
       |> assign(:entries, Nerve.list_entries(user.id))
       |> put_flash(:info, "Nerve entry deleted")}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid entry id")}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Entry not found")}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not delete entry")}
    end
  end

  @impl true
  def handle_event("load_secret", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, entry} <- Nerve.get_entry_ciphertext(user.id, entry_id) do
      {:reply,
       %{
         status: "ok",
         encrypted_password: Payloads.encode_payload(entry.encrypted_password),
         encrypted_notes: Payloads.encode_payload(entry.encrypted_notes)
       }, socket}
    else
      _ ->
        {:reply, %{status: "error"}, socket}
    end
  end

  @impl true
  def handle_event("delete_nerve", _params, socket) do
    user = socket.assigns.current_user

    case Nerve.delete_nerve(user.id) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:nerve_configured, false)
         |> assign(:nerve_verifier, nil)
         |> assign(:entries, [])
         |> assign(:form, entry_form(user.id))
         |> put_flash(:info, "Nerve deleted. Create a new passphrase to start over.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete Nerve")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pb-2">
      <div
        id="nerve-live"
        phx-hook="Nerve"
        class="pb-2"
        data-nerve-configured={to_string(@nerve_configured)}
        data-nerve-verifier={Payloads.encode_payload(@nerve_verifier)}
      >
        <section class="mx-auto w-full max-w-7xl space-y-6">
          <ENav.e_nav
            active_tab="nerve"
            current_user={@current_user}
          />

          <Elektrine.Components.ExperimentalNotice.experimental_notice message="Nerve is experimental. Keep separate backups of important passwords and recovery codes while this feature is being tested." />

          <div class="grid gap-6 lg:grid-cols-2">
            <div class="card panel-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <%= if @nerve_configured do %>
                  <h2 class="card-title mb-4 text-lg">Unlock Nerve</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Your passphrase never leaves this browser session.
                  </p>

                  <div class="space-y-3">
                    <input
                      id="nerve-passphrase"
                      type="password"
                      class="input input-bordered w-full"
                      placeholder="Enter Nerve passphrase"
                      autocomplete="current-password"
                      data-nerve-passphrase-input
                    />

                    <div class="flex flex-col gap-2 sm:flex-row">
                      <button type="button" class="btn btn-primary btn-sm flex-1" data-nerve-unlock>
                        Unlock
                      </button>
                      <button type="button" class="btn btn-outline btn-sm flex-1" data-nerve-lock>
                        Lock
                      </button>
                    </div>

                    <p class="text-xs text-base-content/70" data-nerve-status>Nerve locked.</p>
                  </div>
                <% else %>
                  <h2 class="card-title mb-4 text-lg">Set Nerve Passphrase</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Create your Nerve passphrase before saving any credentials.
                  </p>

                  <form id="nerve-setup-form" phx-submit="setup_nerve" data-nerve-setup-form>
                    <div class="space-y-3">
                      <input
                        type="password"
                        name="_nerve_setup_passphrase"
                        class="input input-bordered w-full"
                        placeholder="New Nerve passphrase"
                        autocomplete="new-password"
                        data-nerve-setup-passphrase
                      />
                      <input
                        type="password"
                        name="_nerve_setup_passphrase_confirm"
                        class="input input-bordered w-full"
                        placeholder="Confirm passphrase"
                        autocomplete="new-password"
                        data-nerve-setup-passphrase-confirm
                      />

                      <input
                        type="hidden"
                        name="nerve[encrypted_verifier]"
                        data-nerve-setup-encrypted-verifier
                      />

                      <button
                        type="button"
                        class="btn btn-primary btn-sm w-full"
                        data-nerve-setup-submit
                      >
                        Create Nerve
                      </button>
                    </div>
                  </form>
                <% end %>
              </div>
            </div>

            <div class="card panel-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Security Notes</h2>
                <ul class="list-disc space-y-3 pl-5 text-sm text-base-content/70">
                  <li>Only encrypted Nerve payloads are stored server-side.</li>
                  <li>Secrets are revealed only in this browser after local decryption.</li>
                  <li>If you lose your Nerve passphrase, saved secrets cannot be recovered.</li>
                  <li>Use unique passwords for every service.</li>
                </ul>

                <%= if @nerve_configured do %>
                  <div class="mt-5 rounded-lg border border-error/30 bg-error/5 p-4">
                    <p class="mb-3 text-sm text-base-content/70">
                      Lost your passphrase? Delete Nerve and all saved entries, then create a
                      new one.
                    </p>
                    <button
                      id="delete-nerve-button"
                      type="button"
                      phx-click="delete_nerve"
                      data-confirm="Delete Nerve and all saved entries? This cannot be undone."
                      class="btn btn-error btn-outline btn-sm"
                    >
                      Delete Nerve
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <div class="grid gap-6 xl:grid-cols-3">
            <div class="card panel-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <div class="mb-4 flex items-start justify-between gap-3">
                  <div>
                    <h2 class="card-title mt-1 text-lg">Install Browser Extension</h2>
                  </div>
                  <span class="badge badge-primary badge-outline">Extension</span>
                </div>

                <p class="text-sm text-base-content/70">
                  Add the browser extension to unlock autofill, page capture, and future relay actions from the sites you use.
                </p>

                <div class="mt-5 grid gap-2">
                  <a
                    href="/account/nerve/extension/chromium/download"
                    class="btn btn-primary btn-sm"
                  >
                    Download Chromium ZIP
                  </a>
                  <a
                    href="/account/nerve/extension/firefox/download"
                    class="btn btn-outline btn-sm"
                  >
                    Download Firefox XPI
                  </a>
                </div>

                <ol class="mt-5 list-decimal space-y-2 pl-5 text-xs text-base-content/60">
                  <li>Install the browser extension.</li>
                  <li>Open the browser extension and unlock Nerve in this browser.</li>
                  <li>Use saved entries on matching sites.</li>
                </ol>
              </div>
            </div>

            <div class="card panel-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <div class="mb-4 flex items-start justify-between gap-3">
                  <div>
                    <h2 class="card-title mt-1 text-lg">This Browser</h2>
                  </div>
                  <span class={[
                    @nerve_configured && "badge-success",
                    !@nerve_configured && "badge-ghost",
                    "badge"
                  ]}>
                    {if @nerve_configured, do: "Ready", else: "Setup needed"}
                  </span>
                </div>

                <div class="rounded-xl border border-base-300 bg-base-200/50 p-4">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <p class="font-medium">Local browser session</p>
                      <p class="text-xs text-base-content/60">
                        {if @nerve_configured,
                          do: "Unlock Nerve here to decrypt entries locally.",
                          else: "Create a passphrase before connecting devices."}
                      </p>
                    </div>
                    <span class="flex h-8 w-8 items-center justify-center rounded-full bg-base-300 text-sm font-semibold text-base-content/45">
                      B
                    </span>
                  </div>
                </div>

                <div class="mt-4 rounded-xl border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                  Paired browser extension devices will appear here when device registration is enabled.
                </div>
              </div>
            </div>

            <div class="card panel-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <div class="mb-4 flex items-start justify-between gap-3">
                  <div>
                    <h2 class="card-title mt-1 text-lg">Known Sites</h2>
                  </div>
                  <span class="badge badge-outline">{length(site_connection_rows(@entries))}</span>
                </div>

                <%= case site_connection_rows(@entries) do %>
                  <% [] -> %>
                    <div class="rounded-xl border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                      Save entries with websites to see matching sites here. Future relay permissions will live in this section.
                    </div>
                  <% sites -> %>
                    <div class="space-y-3">
                      <div
                        :for={site <- sites}
                        class="rounded-xl border border-base-300 bg-base-200/50 p-3"
                      >
                        <div class="flex items-center justify-between gap-3">
                          <div class="min-w-0">
                            <p class="truncate font-medium">{site.host}</p>
                            <p class="text-xs text-base-content/60">
                              {site.entry_count} saved {if site.entry_count == 1,
                                do: "entry",
                                else: "entries"}
                            </p>
                          </div>
                          <span class="badge badge-ghost whitespace-nowrap">Stored</span>
                        </div>
                      </div>
                    </div>
                <% end %>
              </div>
            </div>
          </div>

          <div class="card panel-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Add Entry</h2>

              <%= if @nerve_configured do %>
                <form id="nerve-entry-form" phx-change="validate" phx-submit="create" data-nerve-form>
                  <div class="space-y-4">
                    <div class="form-control">
                      <label class="label" for="entry-title">
                        <span class="label-text">Title</span>
                      </label>
                      <input
                        id="entry-title"
                        type="text"
                        name="entry[title]"
                        value={@form[:title].value}
                        class="input input-bordered w-full"
                        placeholder="GitHub"
                        required
                      />
                      <p :for={error <- @form[:title].errors} class="mt-1 text-sm text-error">
                        {translate_error(error)}
                      </p>
                    </div>

                    <div class="form-control">
                      <label class="label" for="entry-login-username">
                        <span class="label-text">Username or Email</span>
                      </label>
                      <input
                        id="entry-login-username"
                        type="text"
                        name="entry[login_username]"
                        value={@form[:login_username].value}
                        class="input input-bordered w-full"
                        placeholder="you@example.com"
                      />
                    </div>

                    <div class="form-control">
                      <label class="label" for="entry-website">
                        <span class="label-text">Website</span>
                      </label>
                      <input
                        id="entry-website"
                        type="url"
                        name="entry[website]"
                        value={@form[:website].value}
                        class="input input-bordered w-full"
                        placeholder="https://example.com"
                      />
                      <p :for={error <- @form[:website].errors} class="mt-1 text-sm text-error">
                        {translate_error(error)}
                      </p>
                    </div>

                    <div class="form-control">
                      <div class="label py-0 mb-1">
                        <span class="label-text">Password</span>
                        <button type="button" class="btn btn-xs btn-outline" data-nerve-generate>
                          Generate
                        </button>
                      </div>
                      <input
                        id="nerve-password-input"
                        type="password"
                        class="input input-bordered w-full"
                        autocomplete="new-password"
                        data-nerve-password-input
                      />
                    </div>

                    <div class="form-control">
                      <div class="label py-0 mb-1">
                        <span class="label-text">Notes</span>
                      </div>
                      <textarea
                        id="nerve-notes-input"
                        class="textarea textarea-bordered min-h-[6rem] w-full"
                        placeholder="Optional notes, recovery links, backup codes, etc."
                        data-nerve-notes-input
                      ></textarea>
                    </div>

                    <input
                      type="hidden"
                      name="entry[encrypted_metadata]"
                      data-nerve-encrypted-metadata
                    />
                    <input
                      type="hidden"
                      name="entry[encrypted_password]"
                      data-nerve-encrypted-password
                    />
                    <input type="hidden" name="entry[encrypted_notes]" data-nerve-encrypted-notes />

                    <button
                      type="button"
                      class="btn btn-primary w-full"
                      data-nerve-entry-submit
                    >
                      Save Entry
                    </button>
                  </div>
                </form>
              <% else %>
                <p class="text-sm text-base-content/70">
                  Set your Nerve passphrase first. After setup, this form will unlock.
                </p>
              <% end %>
            </div>
          </div>

          <div class="card panel-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Saved Entries</h2>

              <%= if not @nerve_configured do %>
                <div class="py-10 text-center">
                  <div class="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-base-200 text-base-content/25">
                    <span class="text-lg font-semibold">V</span>
                  </div>
                  <p class="text-sm text-base-content/60">
                    Set up Nerve to start saving entries
                  </p>
                </div>
              <% else %>
                <%= if @entries == [] do %>
                  <div class="py-10 text-center">
                    <div class="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-base-200 text-base-content/25">
                      <span class="text-lg font-semibold">V</span>
                    </div>
                    <p class="text-sm text-base-content/60">No entries yet</p>
                  </div>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="table">
                      <thead>
                        <tr>
                          <th>Title</th>
                          <th class="hidden md:table-cell">Login</th>
                          <th class="hidden lg:table-cell">Website</th>
                          <th class="hidden sm:table-cell">Created</th>
                          <th>Actions</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for entry <- @entries do %>
                          <tr
                            id={"entry-#{entry.id}"}
                            data-nerve-entry-id={entry.id}
                            data-nerve-title={entry.title}
                            data-nerve-login-username={entry.login_username || ""}
                            data-nerve-website={entry.website || ""}
                            data-encrypted-metadata={
                              Payloads.encode_payload(entry.encrypted_metadata)
                            }
                          >
                            <td class="font-medium" data-nerve-title-output>{entry.title}</td>
                            <td
                              class="hidden text-sm text-base-content/70 md:table-cell"
                              data-nerve-username-output
                            >
                              {entry.login_username || "-"}
                            </td>
                            <td class="hidden text-sm lg:table-cell" data-nerve-website-output>
                              <%= if entry.website do %>
                                <a
                                  href={entry.website}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  class="link link-hover"
                                >
                                  {entry.website}
                                </a>
                              <% else %>
                                <span class="text-base-content/50">-</span>
                              <% end %>
                            </td>
                            <td class="hidden text-sm text-base-content/70 sm:table-cell">
                              {format_inserted_at(entry.inserted_at)}
                            </td>
                            <td>
                              <div class="flex gap-2">
                                <button
                                  type="button"
                                  class="btn btn-xs btn-primary"
                                  data-nerve-reveal={entry.id}
                                  data-reveal-label="Reveal"
                                  data-hide-label="Hide"
                                >
                                  Reveal
                                </button>

                                <button
                                  type="button"
                                  phx-click="delete"
                                  phx-value-id={entry.id}
                                  data-confirm="Delete this nerve entry?"
                                  class="btn btn-xs btn-error btn-outline"
                                >
                                  Delete
                                </button>
                              </div>
                            </td>
                          </tr>

                          <tr
                            id={"entry-secret-#{entry.id}"}
                            data-nerve-secret-row={entry.id}
                            class="hidden"
                          >
                            <td colspan="5">
                              <div class="rounded-lg bg-base-200 p-4 space-y-3">
                                <div>
                                  <p class="mb-1 text-xs uppercase tracking-wide text-base-content/60">
                                    Password
                                  </p>
                                  <code
                                    id={"password-#{entry.id}"}
                                    data-nerve-password-output
                                    class="break-all font-mono text-sm"
                                  >
                                  </code>
                                </div>

                                <div data-nerve-notes-wrapper class="hidden">
                                  <p class="mb-1 text-xs uppercase tracking-wide text-base-content/60">
                                    Notes
                                  </p>
                                  <pre
                                    id={"notes-#{entry.id}"}
                                    data-nerve-notes-output
                                    class="whitespace-pre-wrap text-sm font-sans"
                                  ></pre>
                                </div>
                              </div>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp entry_form(user_id, attrs \\ %{}, action \\ nil) do
    params = attrs |> normalize_params() |> Map.put("user_id", user_id)
    changeset = NerveEntry.form_changeset(%NerveEntry{}, params)
    changeset = if action, do: %{changeset | action: action}, else: changeset
    to_form(changeset, as: :entry)
  end

  defp normalize_params(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc -> Map.put(acc, normalize_key(key), value) end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp parse_entry_id(id) do
    case Integer.parse(to_string(id)) do
      {entry_id, ""} -> {:ok, entry_id}
      _ -> :error
    end
  end

  defp translate_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp format_inserted_at(nil), do: "-"
  defp format_inserted_at(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")

  defp site_connection_rows(entries) when is_list(entries) do
    entries
    |> Enum.map(& &1.website)
    |> Enum.reject(&blank?/1)
    |> Enum.map(&site_connection_host/1)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.map(fn {host, entry_count} -> %{host: host, entry_count: entry_count} end)
    |> Enum.sort_by(& &1.host)
  end

  defp site_connection_rows(_entries), do: []

  defp site_connection_host(value) when is_binary(value) do
    value
    |> String.trim()
    |> URI.parse()
    |> case do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp site_connection_host(_value), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
