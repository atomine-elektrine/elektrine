defmodule ElektrineWeb.SettingsLive.PasswordManager do
  use ElektrineWeb, :live_view

  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.VaultEntry

  import ElektrineWeb.Components.Platform.ZNav

  on_mount({ElektrineWeb.Live.AuthHooks, :require_authenticated_user})

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    vault_settings = PasswordManager.get_vault_settings(user.id)
    vault_configured = not is_nil(vault_settings)

    entries =
      if vault_configured,
        do: PasswordManager.list_entries(user.id, include_secrets: true),
        else: []

    {:ok,
     socket
     |> assign(:page_title, "Password Manager")
     |> assign(:vault_configured, vault_configured)
     |> assign(:vault_verifier, vault_settings && vault_settings.encrypted_verifier)
     |> assign(:entries, entries)
     |> assign(:form, entry_form(user.id))}
  end

  @impl true
  def handle_event("validate", %{"entry" => params}, socket) do
    user = socket.assigns.current_user
    form = entry_form(user.id, params, :validate)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("create", %{"entry" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- decode_encrypted_params(params),
         {:ok, _entry} <- PasswordManager.create_entry(user.id, params) do
      {:noreply,
       socket
       |> assign(:entries, PasswordManager.list_entries(user.id, include_secrets: true))
       |> assign(:form, entry_form(user.id))
       |> put_flash(:info, "Vault entry saved")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         socket |> put_flash(:error, "Vault payload is invalid. Unlock your vault and try again.")}

      {:error, :vault_not_configured} ->
        {:noreply,
         socket |> put_flash(:error, "Set up your vault passphrase before saving entries.")}

      {:error, changeset} ->
        changeset = %{changeset | action: :insert}
        {:noreply, assign(socket, :form, to_form(changeset, as: :entry))}
    end
  end

  @impl true
  def handle_event("setup_vault", %{"vault" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- decode_setup_params(params),
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
         socket
         |> put_flash(:error, "Vault setup payload is invalid. Use the setup form to continue.")}

      {:error, changeset} ->
        details =
          changeset.errors
          |> Keyword.keys()
          |> Enum.map(&to_string/1)
          |> Enum.join(", ")

        message =
          if details == "" do
            "Could not configure vault."
          else
            "Could not configure vault (#{details})."
          end

        {:noreply, socket |> put_flash(:error, message)}
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
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pb-2">
      <.z_nav active_tab="password_manager" />

      <div
        id="password-vault-live"
        phx-hook="PasswordVault"
        class="max-w-5xl mx-auto p-4 sm:p-6"
        data-vault-configured={to_string(@vault_configured)}
        data-vault-verifier={encode_payload(@vault_verifier)}
      >
        <div class="mb-6 sm:mb-8">
          <h1 class="text-2xl sm:text-3xl font-bold text-base-content">Password Manager</h1>
          <p class="text-base-content/70 mt-2">
            Vault secrets are encrypted and decrypted in your browser with your vault passphrase.
          </p>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card glass-card shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <%= if @vault_configured do %>
                <h2 class="card-title text-lg mb-4">Unlock Vault</h2>
                <p class="text-sm text-base-content/70 mb-4">
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

                  <div class="flex flex-col sm:flex-row gap-2">
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
                <h2 class="card-title text-lg mb-4">Set Vault Passphrase</h2>
                <p class="text-sm text-base-content/70 mb-4">
                  Create your vault passphrase before saving any credentials.
                </p>

                <.form id="vault-setup-form" for={%{}} phx-submit="setup_vault" data-vault-setup-form>
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
                </.form>
              <% end %>
            </div>
          </div>

          <div class="card glass-card shadow-lg">
            <div class="card-body p-4 sm:p-6">
              <h2 class="card-title text-lg mb-4">Security Notes</h2>
              <ul class="space-y-3 text-sm text-base-content/70 list-disc pl-5">
                <li>Only encrypted vault payloads are stored server-side.</li>
                <li>Secrets are revealed only in this browser after local decryption.</li>
                <li>If you lose your vault passphrase, saved secrets cannot be recovered.</li>
                <li>Use unique passwords for every service.</li>
              </ul>
            </div>
          </div>
        </div>

        <div class="card glass-card shadow-lg mt-6">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">Add Entry</h2>

            <%= if @vault_configured do %>
              <.simple_form
                id="vault-entry-form"
                for={@form}
                bare={true}
                phx-change="validate"
                phx-submit="create"
                data-vault-form
              >
                <.input field={@form[:title]} label="Title" placeholder="GitHub" required />
                <.input
                  field={@form[:login_username]}
                  label="Username or Email"
                  placeholder="you@example.com"
                />
                <.input
                  field={@form[:website]}
                  label="Website"
                  type="url"
                  placeholder="https://example.com"
                />

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
                    class="textarea textarea-bordered w-full min-h-[6rem]"
                    placeholder="Optional notes, recovery links, backup codes, etc."
                    data-vault-notes-input
                  ></textarea>
                </div>

                <input type="hidden" name="entry[encrypted_password]" data-vault-encrypted-password />
                <input type="hidden" name="entry[encrypted_notes]" data-vault-encrypted-notes />

                <:actions>
                  <.button type="button" class="btn btn-primary w-full" data-vault-entry-submit>
                    Save Entry
                  </.button>
                </:actions>
              </.simple_form>
            <% else %>
              <p class="text-sm text-base-content/70">
                Set your vault passphrase first. After setup, this form will unlock.
              </p>
            <% end %>
          </div>
        </div>

        <div class="card glass-card shadow-lg mt-6">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">Saved Entries</h2>

            <%= if not @vault_configured do %>
              <div class="text-center py-10">
                <.icon name="hero-lock-closed" class="w-10 h-10 mx-auto text-base-content/25 mb-3" />
                <p class="text-sm text-base-content/60">Set up your vault to start saving entries</p>
              </div>
            <% else %>
              <%= if @entries == [] do %>
                <div class="text-center py-10">
                  <.icon name="hero-lock-closed" class="w-10 h-10 mx-auto text-base-content/25 mb-3" />
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
                          data-encrypted-password={encode_payload(entry.encrypted_password)}
                          data-encrypted-notes={encode_payload(entry.encrypted_notes)}
                        >
                          <td class="font-medium">{entry.title}</td>
                          <td class="hidden md:table-cell text-sm text-base-content/70">
                            {entry.login_username || "-"}
                          </td>
                          <td class="hidden lg:table-cell text-sm">
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
                          <td class="hidden sm:table-cell text-sm text-base-content/70">
                            <.local_time datetime={entry.inserted_at} format="date" />
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
                            <div class="bg-base-200 rounded-lg p-4 space-y-3">
                              <div>
                                <p class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                                  Password
                                </p>
                                <code
                                  id={"password-#{entry.id}"}
                                  data-vault-password-output
                                  class="font-mono text-sm break-all"
                                >
                                </code>
                              </div>

                              <div data-vault-notes-wrapper class="hidden">
                                <p class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                                  Notes
                                </p>
                                <pre
                                  id={"notes-#{entry.id}"}
                                  data-vault-notes-output
                                  class="text-sm whitespace-pre-wrap font-sans"
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
      </div>
    </div>
    """
  end

  defp entry_form(user_id, attrs \\ %{}, action \\ nil) do
    params = attrs |> normalize_params() |> Map.put("user_id", user_id)
    changeset = %VaultEntry{} |> VaultEntry.form_changeset(params)

    changeset =
      if action do
        %{changeset | action: action}
      else
        changeset
      end

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

  defp decode_setup_params(params) when is_map(params) do
    with {:ok, params} <- decode_payload_field(params, "encrypted_verifier", required: true) do
      {:ok, params}
    end
  end

  defp decode_setup_params(_params), do: {:error, :invalid_payload}

  defp decode_encrypted_params(params) when is_map(params) do
    with {:ok, params} <- decode_payload_field(params, "encrypted_password", required: true),
         {:ok, params} <- decode_payload_field(params, "encrypted_notes", required: false) do
      {:ok, params}
    end
  end

  defp decode_encrypted_params(_params), do: {:error, :invalid_payload}

  defp decode_payload_field(params, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case Map.get(params, field) do
      nil ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, params}

      "" ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, Map.put(params, field, nil)}

      value when is_map(value) ->
        {:ok, params}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> {:ok, Map.put(params, field, decoded)}
          _ -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp encode_payload(nil), do: ""
  defp encode_payload(payload) when is_map(payload), do: Jason.encode!(payload)
end
