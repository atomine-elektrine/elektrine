defmodule ElektrineWeb.SettingsLive.PasswordManager do
  use ElektrineWeb, :live_view

  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.VaultEntry

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Password Manager")
     |> assign(:entries, PasswordManager.list_entries(user.id))
     |> assign(:revealed_entries, %{})
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

    case PasswordManager.create_entry(user.id, params) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:entries, PasswordManager.list_entries(user.id))
         |> assign(:form, entry_form(user.id))
         |> put_flash(:info, "Vault entry saved")}

      {:error, changeset} ->
        changeset = %{changeset | action: :insert}
        {:noreply, assign(socket, :form, to_form(changeset, as: :entry))}
    end
  end

  @impl true
  def handle_event("reveal", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, entry} <- PasswordManager.get_entry(user.id, entry_id) do
      revealed = %{password: entry.password, notes: entry.notes}

      {:noreply,
       update(socket, :revealed_entries, fn revealed_entries ->
         Map.put(revealed_entries, entry_id, revealed)
       end)}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid entry id")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Entry not found")}

      {:error, :decryption_failed} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt this entry")}
    end
  end

  @impl true
  def handle_event("hide", %{"id" => id}, socket) do
    with {:ok, entry_id} <- parse_entry_id(id) do
      {:noreply,
       update(socket, :revealed_entries, fn revealed_entries ->
         Map.delete(revealed_entries, entry_id)
       end)}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid entry id")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      {:noreply,
       socket
       |> assign(:entries, PasswordManager.list_entries(user.id))
       |> update(:revealed_entries, fn revealed_entries ->
         Map.delete(revealed_entries, entry_id)
       end)
       |> put_flash(:info, "Vault entry deleted")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid entry id")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Entry not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete entry")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-4 sm:p-6">
      <div class="mb-6 sm:mb-8">
        <h1 class="text-2xl sm:text-3xl font-bold text-base-content">Password Manager</h1>
        <p class="text-base-content/70 mt-2">
          Save credentials in an encrypted vault. Passwords are decrypted only when you reveal them.
        </p>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="card glass-card shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">Add Entry</h2>

            <.simple_form
              id="vault-entry-form"
              for={@form}
              bare={true}
              phx-change="validate"
              phx-submit="create"
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
              <.input field={@form[:password]} label="Password" type="password" required />
              <.input
                field={@form[:notes]}
                label="Notes"
                type="textarea"
                placeholder="Optional notes, recovery links, backup codes, etc."
              />

              <:actions>
                <.button class="btn btn-primary w-full">Save Entry</.button>
              </:actions>
            </.simple_form>
          </div>
        </div>

        <div class="card glass-card shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">Security Notes</h2>
            <ul class="space-y-3 text-sm text-base-content/70 list-disc pl-5">
              <li>Vault data is encrypted with your account-specific encryption key.</li>
              <li>Only reveal passwords when needed, then hide them again.</li>
              <li>Use unique passwords for every service.</li>
              <li>Delete entries you no longer use.</li>
            </ul>
          </div>
        </div>
      </div>

      <div class="card glass-card shadow-lg mt-6">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-lg mb-4">Saved Entries</h2>

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
                    <tr id={"entry-#{entry.id}"}>
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
                          <%= if Map.has_key?(@revealed_entries, entry.id) do %>
                            <button
                              type="button"
                              phx-click="hide"
                              phx-value-id={entry.id}
                              class="btn btn-xs btn-outline"
                            >
                              Hide
                            </button>
                          <% else %>
                            <button
                              type="button"
                              phx-click="reveal"
                              phx-value-id={entry.id}
                              class="btn btn-xs btn-primary"
                            >
                              Reveal
                            </button>
                          <% end %>

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
                      :if={Map.has_key?(@revealed_entries, entry.id)}
                      id={"entry-secret-#{entry.id}"}
                    >
                      <td colspan="5">
                        <% revealed = @revealed_entries[entry.id] %>
                        <div class="bg-base-200 rounded-lg p-4 space-y-3">
                          <div>
                            <p class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                              Password
                            </p>
                            <code id={"password-#{entry.id}"} class="font-mono text-sm break-all">
                              {revealed.password}
                            </code>
                          </div>

                          <%= if revealed.notes do %>
                            <div>
                              <p class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                                Notes
                              </p>
                              <pre
                                id={"notes-#{entry.id}"}
                                class="text-sm whitespace-pre-wrap font-sans"
                              >{revealed.notes}</pre>
                            </div>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp entry_form(user_id, attrs \\ %{}, action \\ nil) do
    params =
      attrs
      |> normalize_params()
      |> Map.put("user_id", user_id)

    changeset =
      %VaultEntry{}
      |> VaultEntry.form_changeset(params)

    changeset =
      if action do
        %{changeset | action: action}
      else
        changeset
      end

    to_form(changeset, as: :entry)
  end

  defp normalize_params(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp parse_entry_id(id) do
    case Integer.parse(to_string(id)) do
      {entry_id, ""} -> {:ok, entry_id}
      _ -> :error
    end
  end
end
