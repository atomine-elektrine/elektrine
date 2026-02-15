defmodule ElektrineWeb.SettingsLive.AppPasswords do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    app_passwords = Accounts.list_app_passwords(user.id)

    {:ok,
     socket
     |> assign(:app_passwords, app_passwords)
     |> assign(:new_token, nil)
     |> assign(:form, to_form(%{}))}
  end

  @impl true
  def handle_event("create", params, socket) do
    user = socket.assigns.current_user
    name = params["name"]
    expires_option = params["expires_at"]

    # Calculate expiration date based on selection
    expires_at =
      case expires_option do
        "30_days" -> DateTime.utc_now() |> DateTime.add(30, :day)
        "90_days" -> DateTime.utc_now() |> DateTime.add(90, :day)
        "1_year" -> DateTime.utc_now() |> DateTime.add(365, :day)
        "never" -> nil
        _ -> nil
      end

    case Accounts.create_app_password(user.id, %{name: name, expires_at: expires_at}) do
      {:ok, app_password} ->
        app_passwords = Accounts.list_app_passwords(user.id)

        {:noreply,
         socket
         |> assign(:app_passwords, app_passwords)
         |> assign(:new_token, app_password.token)
         |> put_flash(:info, "App password created successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create app password")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Accounts.delete_app_password(id, user.id) do
      {:ok, _} ->
        app_passwords = Accounts.list_app_passwords(user.id)

        {:noreply,
         socket
         |> assign(:app_passwords, app_passwords)
         |> put_flash(:info, "App password deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete app password")}
    end
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4 sm:p-6">
      <div class="mb-6 sm:mb-8">
        <h1 class="text-2xl sm:text-3xl font-bold text-base-content">{gettext("App Passwords")}</h1>
        <p class="text-base-content/70 mt-2">
          {gettext("Manage app-specific passwords for email clients")}
        </p>
      </div>
      
    <!-- Information Card -->
      <div class="card glass-card shadow-lg mb-6">
        <div class="card-body p-4 sm:p-6">
          <div class="flex items-start gap-3">
            <.icon name="hero-information-circle" class="w-5 h-5 text-info mt-0.5" />
            <div class="text-sm text-base-content/70">
              <p class="mb-2">
                App passwords let you sign in to your email using POP3/IMAP clients like Thunderbird or Outlook.
              </p>
              <p class="mb-2">
                These passwords work even if you have two-factor authentication enabled.
              </p>
              <p class="font-semibold">
                Important: Each password is shown only once when created.
              </p>
            </div>
          </div>
        </div>
      </div>
      
    <!-- New Token Modal -->
      <%= if @new_token do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-md">
            <h3 class="font-bold text-lg mb-4 flex items-center gap-2 text-success">
              <.icon name="hero-check-circle" class="w-6 h-6" /> App Password Created!
            </h3>

            <div class="alert alert-warning mb-4">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 flex-shrink-0" />
              <span class="text-sm">This password won't be shown again. Copy it now!</span>
            </div>

            <div class="form-control mb-4">
              <label class="label">
                <span class="label-text text-sm font-semibold">Your app password:</span>
              </label>
              <div class="bg-base-200 rounded-lg p-4 text-center">
                <code class="text-lg font-mono select-all">{@new_token}</code>
              </div>
            </div>

            <div class="bg-base-200 rounded-lg p-3 mb-4">
              <p class="text-xs text-base-content/70 font-semibold mb-3">
                Email client configuration:
              </p>
              <div class="text-xs text-base-content/60 space-y-3">
                <div>
                  <p class="font-semibold mb-1">IMAP (Recommended):</p>
                  <p>• Server: imap.elektrine.com</p>
                  <p>• Port: 993 (IMAP with TLS)</p>
                </div>
                <div>
                  <p class="font-semibold mb-1">SMTP (Outgoing):</p>
                  <p>• Server: smtp.elektrine.com</p>
                  <p>• Port: 465 (SMTP with TLS)</p>
                </div>
                <div>
                  <p class="font-semibold mb-1">POP3 (Alternative):</p>
                  <p>• Server: pop.elektrine.com</p>
                  <p>• Port: 995 (POP3 with TLS)</p>
                </div>
                <div class="pt-2 border-t border-base-300">
                  <p>• Username: Your elektrine username</p>
                  <p>• Password: The app password shown above</p>
                </div>
              </div>
            </div>

            <div class="modal-action">
              <button phx-click="dismiss_token" class="btn btn-primary">
                I've saved this password
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="dismiss_token"></div>
        </div>
      <% end %>

      <div class="grid gap-6 lg:grid-cols-2">
        <!-- Create New App Password -->
        <div class="card glass-card shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">Create App Password</h2>
            <.form for={@form} phx-submit="create">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">App name</span>
                </label>
                <input
                  type="text"
                  name="name"
                  placeholder="e.g., Thunderbird on laptop"
                  class="input input-bordered"
                  required
                  maxlength="100"
                />
                <label class="label">
                  <span class="label-text-alt text-xs">
                    Give it a name to remember which app uses this password
                  </span>
                </label>
              </div>

              <div class="form-control mt-4">
                <label class="label">
                  <span class="label-text">Expires</span>
                </label>
                <select name="expires_at" class="select select-bordered">
                  <option value="never">Never</option>
                  <option value="30_days">30 days</option>
                  <option value="90_days">90 days</option>
                  <option value="1_year">1 year</option>
                </select>
                <label class="label">
                  <span class="label-text-alt text-xs">
                    Password will automatically stop working after this period
                  </span>
                </label>
              </div>

              <div class="card-actions mt-4">
                <button type="submit" class="btn btn-primary w-full">
                  <.icon name="hero-plus" class="w-4 h-4" /> Create Password
                </button>
              </div>
            </.form>
          </div>
        </div>
        
    <!-- Usage Instructions -->
        <div class="card glass-card shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg mb-4">How to Use</h2>
            <div class="space-y-3 text-sm text-base-content/70">
              <div class="flex items-start gap-2">
                <span class="badge badge-sm mt-0.5">1</span>
                <p>Create an app password with a descriptive name</p>
              </div>
              <div class="flex items-start gap-2">
                <span class="badge badge-sm mt-0.5">2</span>
                <p>Copy the generated password immediately (it won't be shown again)</p>
              </div>
              <div class="flex items-start gap-2">
                <span class="badge badge-sm mt-0.5">3</span>
                <p>Use this password in your email client instead of your account password</p>
              </div>
              <div class="flex items-start gap-2">
                <span class="badge badge-sm mt-0.5">4</span>
                <p>Delete the app password when you no longer need it</p>
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Existing App Passwords -->
      <div class="card glass-card shadow-lg mt-6">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-lg mb-4">Existing App Passwords</h2>

          <%= if @app_passwords == [] do %>
            <div class="text-center py-8">
              <.icon name="hero-key" class="w-12 h-12 mx-auto text-base-content/20 mb-3" />
              <p class="text-sm text-base-content/60">No app passwords created yet</p>
              <p class="text-xs text-base-content/40 mt-1">
                Create one above to connect your email client
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Created</th>
                    <th class="hidden sm:table-cell">Last Used</th>
                    <th class="hidden md:table-cell">Expires</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for app_password <- @app_passwords do %>
                    <tr>
                      <td>
                        <div class="font-medium">{app_password.name}</div>
                      </td>
                      <td class="text-sm text-base-content/70">
                        <.local_time datetime={app_password.inserted_at} format="date" />
                      </td>
                      <td class="text-sm text-base-content/70 hidden sm:table-cell">
                        <%= if app_password.last_used_at do %>
                          <div>
                            <.local_time datetime={app_password.last_used_at} format="datetime" />
                            <%= if app_password.last_used_ip do %>
                              <div class="text-xs text-base-content/50">
                                from {app_password.last_used_ip}
                              </div>
                            <% end %>
                          </div>
                        <% else %>
                          <span class="text-base-content/40">Never</span>
                        <% end %>
                      </td>
                      <td class="text-sm text-base-content/70 hidden md:table-cell">
                        <%= if app_password.expires_at do %>
                          <% days_until =
                            DateTime.diff(app_password.expires_at, DateTime.utc_now(), :day) %>
                          <%= if days_until < 0 do %>
                            <span class="text-error">Expired</span>
                          <% else %>
                            <div>
                              <.local_time datetime={app_password.expires_at} format="date" />
                              <%= if days_until <= 7 do %>
                                <div class="text-xs text-warning">
                                  {days_until} days left
                                </div>
                              <% end %>
                            </div>
                          <% end %>
                        <% else %>
                          <span class="text-base-content/40">Never</span>
                        <% end %>
                      </td>
                      <td>
                        <button
                          phx-click="delete"
                          phx-value-id={app_password.id}
                          data-confirm="Delete this app password? Any apps using it will lose access."
                          class="btn btn-ghost btn-sm text-error"
                        >
                          <.icon name="hero-trash" class="w-4 h-4" /> Delete
                        </button>
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
end
