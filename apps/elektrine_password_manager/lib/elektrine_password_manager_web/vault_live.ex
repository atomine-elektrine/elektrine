defmodule ElektrinePasswordManagerWeb.VaultLive do
  @moduledoc """
  Dedicated vault management LiveView extracted into the password manager app.
  """

  use ElektrinePasswordManagerWeb, :live_view

  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.Payloads
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.Platform.Modules
  alias Elektrine.Platform.ENavComponent

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    vault_settings = PasswordManager.get_vault_settings(user.id)
    vault_configured = not is_nil(vault_settings)
    active_announcements = Elektrine.Admin.list_active_announcements_for_user(user.id)

    entries =
      if vault_configured,
        do: PasswordManager.list_entries(user.id, include_secrets: true),
        else: []

    {:ok,
     socket
     |> assign(:page_title, "Password Manager")
     |> assign(:active_announcements, active_announcements)
     |> assign(:vault_configured, vault_configured)
     |> assign(:vault_verifier, vault_settings && vault_settings.encrypted_verifier)
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
         {:ok, _entry} <- PasswordManager.create_entry(user.id, params) do
      {:noreply,
       socket
       |> assign(:entries, PasswordManager.list_entries(user.id, include_secrets: true))
       |> assign(:form, entry_form(user.id))
       |> put_flash(:info, "Vault entry saved")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         put_flash(socket, :error, "Vault payload is invalid. Unlock your vault and try again.")}

      {:error, :vault_not_configured} ->
        {:noreply,
         put_flash(socket, :error, "Set up your vault passphrase before saving entries.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(%{changeset | action: :insert}, as: :entry))}
    end
  end

  @impl true
  def handle_event("setup_vault", %{"vault" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- Payloads.decode_setup_params(params),
         {:ok, settings} <- PasswordManager.setup_vault(user.id, params) do
      {:noreply,
       socket
       |> assign(:vault_configured, true)
       |> assign(:vault_verifier, settings.encrypted_verifier)
       |> assign(:entries, PasswordManager.list_entries(user.id, include_secrets: true))
       |> put_flash(:info, "Vault configured")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Vault setup payload is invalid. Use the setup form to continue."
         )}

      {:error, changeset} ->
        details =
          changeset.errors
          |> Keyword.keys()
          |> Enum.map_join(", ", &to_string/1)

        message =
          if details == "" do
            "Could not configure vault."
          else
            "Could not configure vault (#{details})."
          end

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      {:noreply,
       socket
       |> assign(:entries, PasswordManager.list_entries(user.id, include_secrets: true))
       |> put_flash(:info, "Vault entry deleted")}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid entry id")}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Entry not found")}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not delete entry")}
    end
  end

  @impl true
  def handle_event("delete_vault", _params, socket) do
    user = socket.assigns.current_user

    case PasswordManager.delete_vault(user.id) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:vault_configured, false)
         |> assign(:vault_verifier, nil)
         |> assign(:entries, [])
         |> assign(:form, entry_form(user.id))
         |> put_flash(:info, "Vault deleted. Create a new passphrase to start over.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete vault")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pb-2">
      <div
        id="password-vault-live"
        phx-hook="PasswordVault"
        class="pb-2"
        data-vault-configured={to_string(@vault_configured)}
        data-vault-verifier={Payloads.encode_payload(@vault_verifier)}
      >
        <.account_page
          title="Password Manager"
          subtitle="Store credentials in your encrypted vault and manage browser access."
          max_width="max-w-7xl"
          current_user={@current_user}
        >
          <div class="grid gap-6 lg:grid-cols-2">
            <div class="card glass-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <%= if @vault_configured do %>
                  <h2 class="card-title mb-4 text-lg">Unlock Vault</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Your passphrase never leaves this browser session.
                  </p>

                  <div class="space-y-3">
                    <input
                      id="vault-passphrase"
                      type="password"
                      class="input input-bordered w-full"
                      placeholder="Enter vault passphrase"
                      autocomplete="current-password"
                      data-vault-passphrase-input
                    />

                    <div class="flex flex-col gap-2 sm:flex-row">
                      <button type="button" class="btn btn-primary btn-sm flex-1" data-vault-unlock>
                        Unlock
                      </button>
                      <button type="button" class="btn btn-outline btn-sm flex-1" data-vault-lock>
                        Lock
                      </button>
                    </div>

                    <p class="text-xs text-base-content/70" data-vault-status>Vault locked.</p>
                  </div>
                <% else %>
                  <h2 class="card-title mb-4 text-lg">Set Vault Passphrase</h2>
                  <p class="mb-4 text-sm text-base-content/70">
                    Create your vault passphrase before saving any credentials.
                  </p>

                  <form id="vault-setup-form" phx-submit="setup_vault" data-vault-setup-form>
                    <div class="space-y-3">
                      <input
                        type="password"
                        name="_vault_setup_passphrase"
                        class="input input-bordered w-full"
                        placeholder="New vault passphrase"
                        autocomplete="new-password"
                        data-vault-setup-passphrase
                      />
                      <input
                        type="password"
                        name="_vault_setup_passphrase_confirm"
                        class="input input-bordered w-full"
                        placeholder="Confirm passphrase"
                        autocomplete="new-password"
                        data-vault-setup-passphrase-confirm
                      />

                      <input
                        type="hidden"
                        name="vault[encrypted_verifier]"
                        data-vault-setup-encrypted-verifier
                      />

                      <button
                        type="button"
                        class="btn btn-primary btn-sm w-full"
                        data-vault-setup-submit
                      >
                        Create Vault
                      </button>
                    </div>
                  </form>
                <% end %>
              </div>
            </div>

            <div class="card glass-card border border-base-300 shadow-lg">
              <div class="card-body p-4 sm:p-6">
                <h2 class="card-title mb-4 text-lg">Security Notes</h2>
                <ul class="list-disc space-y-3 pl-5 text-sm text-base-content/70">
                  <li>Only encrypted vault payloads are stored server-side.</li>
                  <li>Secrets are revealed only in this browser after local decryption.</li>
                  <li>If you lose your vault passphrase, saved secrets cannot be recovered.</li>
                  <li>Use unique passwords for every service.</li>
                </ul>

                <%= if @vault_configured do %>
                  <div class="mt-5 rounded-lg border border-error/30 bg-error/5 p-4">
                    <p class="mb-3 text-sm text-base-content/70">
                      Lost your passphrase? Delete the vault and all saved entries, then create a
                      new one.
                    </p>
                    <button
                      id="delete-vault-button"
                      type="button"
                      phx-click="delete_vault"
                      data-confirm="Delete your vault and all saved entries? This cannot be undone."
                      class="btn btn-error btn-outline btn-sm"
                    >
                      Delete Vault
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <div class="card glass-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <div class="space-y-2">
                  <h2 class="card-title text-lg">Browser Extensions</h2>
                  <p class="text-sm text-base-content/70">
                    Download the Elektrine Vault extension for your browser and connect it to this account.
                  </p>
                </div>

                <div class="flex flex-col gap-2 sm:flex-row">
                  <a
                    href="/account/password-manager/extension/chromium/download"
                    class="btn btn-primary btn-sm"
                  >
                    Download Chromium ZIP
                  </a>
                  <a
                    href="/account/password-manager/extension/firefox/download"
                    class="btn btn-outline btn-sm"
                  >
                    Download Firefox XPI
                  </a>
                </div>
              </div>
            </div>
          </div>

          <div class="card glass-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Add Entry</h2>

              <%= if @vault_configured do %>
                <form id="vault-entry-form" phx-change="validate" phx-submit="create" data-vault-form>
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
                        <button type="button" class="btn btn-xs btn-outline" data-vault-generate>
                          Generate
                        </button>
                      </div>
                      <input
                        id="vault-password-input"
                        type="password"
                        class="input input-bordered w-full"
                        autocomplete="new-password"
                        data-vault-password-input
                      />
                    </div>

                    <div class="form-control">
                      <div class="label py-0 mb-1">
                        <span class="label-text">Notes</span>
                      </div>
                      <textarea
                        id="vault-notes-input"
                        class="textarea textarea-bordered min-h-[6rem] w-full"
                        placeholder="Optional notes, recovery links, backup codes, etc."
                        data-vault-notes-input
                      ></textarea>
                    </div>

                    <input
                      type="hidden"
                      name="entry[encrypted_password]"
                      data-vault-encrypted-password
                    />
                    <input type="hidden" name="entry[encrypted_notes]" data-vault-encrypted-notes />

                    <button
                      type="button"
                      class="btn btn-primary w-full"
                      data-vault-entry-submit
                    >
                      Save Entry
                    </button>
                  </div>
                </form>
              <% else %>
                <p class="text-sm text-base-content/70">
                  Set your vault passphrase first. After setup, this form will unlock.
                </p>
              <% end %>
            </div>
          </div>

          <div class="card glass-card border border-base-300 shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title mb-4 text-lg">Saved Entries</h2>

              <%= if not @vault_configured do %>
                <div class="py-10 text-center">
                  <div class="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-base-200 text-base-content/25">
                    <span class="text-lg font-semibold">V</span>
                  </div>
                  <p class="text-sm text-base-content/60">
                    Set up your vault to start saving entries
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
                            data-vault-entry-id={entry.id}
                            data-encrypted-password={
                              Payloads.encode_payload(entry.encrypted_password)
                            }
                            data-encrypted-notes={Payloads.encode_payload(entry.encrypted_notes)}
                          >
                            <td class="font-medium">{entry.title}</td>
                            <td class="hidden text-sm text-base-content/70 md:table-cell">
                              {entry.login_username || "-"}
                            </td>
                            <td class="hidden text-sm lg:table-cell">
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
                                  data-vault-reveal={entry.id}
                                  data-reveal-label="Reveal"
                                  data-hide-label="Hide"
                                >
                                  Reveal
                                </button>

                                <button
                                  type="button"
                                  phx-click="delete"
                                  phx-value-id={entry.id}
                                  data-confirm="Delete this vault entry?"
                                  class="btn btn-xs btn-error btn-outline"
                                >
                                  Delete
                                </button>
                              </div>
                            </td>
                          </tr>

                          <tr
                            id={"entry-secret-#{entry.id}"}
                            data-vault-secret-row={entry.id}
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
                                    data-vault-password-output
                                    class="break-all font-mono text-sm"
                                  >
                                  </code>
                                </div>

                                <div data-vault-notes-wrapper class="hidden">
                                  <p class="mb-1 text-xs uppercase tracking-wide text-base-content/60">
                                    Notes
                                  </p>
                                  <pre
                                    id={"notes-#{entry.id}"}
                                    data-vault-notes-output
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
        </.account_page>
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :max_width, :string, default: "max-w-5xl"
  attr :current_user, :any, default: nil
  attr :nav_tab, :string, default: "vault"
  slot :inner_block, required: true

  defp account_page(assigns) do
    ~H"""
    <section class={["mx-auto w-full space-y-4 sm:space-y-6", @max_width]}>
      <.e_nav active_tab={@nav_tab} current_user={@current_user} />
      {render_slot(@inner_block)}
    </section>
    """
  end

  # Keep rendering local, but pull shared nav definitions from the base app so
  # all pages stay in sync.
  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-4"
  attr :current_user, :any, default: nil

  def e_nav(assigns) do
    assigns =
      assigns
      |> assign(:items, nav_items())
      |> assign(:secondary_items, secondary_items(assigns.current_user))

    ENavComponent.render(assigns)
  end

  defp entry_form(user_id, attrs \\ %{}, action \\ nil) do
    params = attrs |> normalize_params() |> Map.put("user_id", user_id)
    changeset = VaultEntry.form_changeset(%VaultEntry{}, params)
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

  defp nav_items, do: Elektrine.Platform.ENav.primary_items() |> Enum.filter(&module_visible?/1)

  defp secondary_items(nil), do: []

  defp secondary_items(_current_user), do: Elektrine.Platform.ENav.secondary_items()

  defp module_visible?(%{platform_module: nil}), do: true
  defp module_visible?(%{platform_module: module}), do: Modules.enabled?(module)

  defp translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  defp format_inserted_at(nil), do: "-"
  defp format_inserted_at(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
end
