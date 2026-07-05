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
    master = Elektrine.Vault.get(user.id)
    active_announcements = Elektrine.Admin.list_active_announcements_for_user(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Nerve")
     |> assign(:active_announcements, active_announcements)
     |> assign(:vault_configured, not is_nil(master))
     |> assign(:wrapped_dek, master && master.wrapped_dek)
     |> assign(:entries, Nerve.list_entries(user.id))
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
         put_flash(socket, :error, "Set up account-password encryption before saving entries.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(%{changeset | action: :insert}, as: :entry))}
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
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 pb-6 sm:px-6 lg:px-8">
      <div
        id="nerve-live"
        phx-hook="Nerve"
        class="pb-2"
        data-vault-configured={to_string(@vault_configured)}
        data-vault-wrapped-dek={@wrapped_dek && Jason.encode!(@wrapped_dek)}
      >
        <section class="mx-auto w-full max-w-7xl space-y-6">
          <ENav.e_nav
            active_tab="nerve"
            current_user={@current_user}
          />

          <div>
            <h1 class="text-2xl font-bold text-base-content sm:text-3xl">Nerve</h1>
            <p class="mt-1 text-base-content/70">
              Encrypted passwords, autofill, and page capture for the browser extension,
              unlocked with your account password.
            </p>
          </div>

          <Elektrine.Components.ExperimentalNotice.experimental_notice message="Nerve is experimental. Keep separate backups of anything important you store here." />

          <div class="grid gap-6 lg:grid-cols-2">
            <div class="card panel-card">
              <div class="card-body p-4 sm:p-6">
                <%= if @vault_configured do %>
                  <h2 class="card-title mb-4 text-lg">Unlock Nerve</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Nerve unlocks with your account password. The encryption key stays in this browser session only.
                  </p>

                  <div class="space-y-3">
                    <input
                      id="nerve-passphrase"
                      type="password"
                      class="input input-bordered w-full"
                      placeholder="Account password"
                      autocomplete="current-password"
                      data-vault-unlock-input
                    />

                    <div class="flex flex-col gap-2 sm:flex-row">
                      <button type="button" class="btn btn-primary btn-sm flex-1" data-vault-unlock>
                        Unlock
                      </button>
                      <button type="button" class="btn btn-surface btn-sm flex-1" data-vault-lock>
                        Lock
                      </button>
                    </div>

                    <p
                      class="text-xs text-base-content/70"
                      data-vault-status
                      data-locked-label="Locked."
                      data-unlocked-label="Unlocked."
                    >
                      Locked.
                    </p>
                    <p class="text-xs text-error" data-vault-error></p>
                  </div>
                <% else %>
                  <h2 class="card-title mb-4 text-lg">Set up account-password encryption</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Nerve uses your account password to unlock encrypted entries. Set this up once
                    and it unlocks Nerve, Kairo, and private email.
                  </p>
                  <.link href="/account/encrypted-data" class="btn btn-primary btn-sm">
                    Set up encryption
                  </.link>
                <% end %>
              </div>
            </div>

            <div class="card panel-card">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Your data</h2>
                <p class="text-sm text-base-content/70">
                  Entries are encrypted under your account vault key and decrypted only in your
                  browser. If your account password is reset, use your recovery code to keep access.
                </p>
              </div>
            </div>
          </div>

          <h2 class="text-lg font-semibold text-base-content">
            Browser extension &amp; integrations
          </h2>

          <div class="grid gap-6 xl:grid-cols-3">
            <div class="card panel-card">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Browser Extension</h2>

                <p class="text-sm text-base-content/70">
                  Autofill saved entries and capture pages from the sites you use.
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
                    class="btn btn-surface btn-sm"
                  >
                    Download Firefox XPI
                  </a>
                </div>

                <p class="mt-5 text-xs text-base-content/60">
                  After installing, open the extension and unlock Nerve.
                </p>
              </div>
            </div>

            <div class="card panel-card">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Kairo Capture</h2>

                <p class="text-sm text-base-content/70">
                  Clip the page you're on - or selected text - straight into <.link
                    href="/kairo"
                    class="link"
                  >Kairo</.link>.
                </p>

                <div class="mt-5 grid gap-2">
                  <.link href="/kairo" class="btn btn-primary btn-sm">Open Kairo</.link>
                  <.link href="/account?tab=developer" class="btn btn-surface btn-sm">
                    Manage API tokens
                  </.link>
                </div>

                <p class="mt-5 text-xs text-base-content/60">
                  Requires an API token with the
                  <code class="rounded bg-base-300/70 px-1">write:kairo</code>
                  scope.
                </p>
              </div>
            </div>

            <div class="card panel-card">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Known Sites</h2>

                <%= case site_connection_rows(@entries) do %>
                  <% [] -> %>
                    <div class="rounded-xl border border-dashed border-base-content/20 p-4 text-sm text-base-content/60">
                      Entries with a website are grouped by site here.
                    </div>
                  <% sites -> %>
                    <div class="space-y-3">
                      <div :for={site <- sites} class="surface-muted rounded-xl p-3">
                        <p class="truncate font-medium">{site.host}</p>
                        <p class="text-xs text-base-content/60">
                          {site.entry_count} saved {if site.entry_count == 1,
                            do: "entry",
                            else: "entries"}
                        </p>
                      </div>
                    </div>
                <% end %>
              </div>
            </div>
          </div>

          <h2 class="text-lg font-semibold text-base-content">Passwords</h2>

          <div class="card panel-card">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Add Entry</h2>

              <%= if @vault_configured do %>
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
                        <button type="button" class="btn btn-xs btn-surface" data-nerve-generate>
                          Generate
                        </button>
                      </div>
                      <div class="relative">
                        <input
                          id="nerve-password-input"
                          type="password"
                          class="input input-bordered w-full pr-10 font-mono"
                          autocomplete="new-password"
                          data-nerve-password-input
                        />
                        <button
                          type="button"
                          class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/50 hover:text-base-content"
                          data-nerve-toggle-password
                          aria-label="Show or hide password"
                        >
                          <span data-nerve-eye-show class="hero-eye h-5 w-5"></span>
                          <span data-nerve-eye-hide class="hero-eye-slash hidden h-5 w-5"></span>
                        </button>
                      </div>
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
                  Set up account-password encryption first. After setup, this form will unlock.
                </p>
              <% end %>
            </div>
          </div>

          <div class="card panel-card">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Saved Entries</h2>

              <%= if not @vault_configured do %>
                <div class="py-10 text-center">
                  <p class="text-sm text-base-content/60">
                    Set up account-password encryption to start saving entries
                  </p>
                </div>
              <% else %>
                <%= if @entries == [] do %>
                  <div class="py-10 text-center">
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
                              <div class="surface-muted rounded-lg p-4 space-y-3">
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
