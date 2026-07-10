defmodule ElektrineWeb.SettingsLive.AppPasswords do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts
  alias Elektrine.MailClientSettings
  alias ElektrineWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    app_passwords = Accounts.list_app_passwords(user.id)

    {:ok,
     socket
     |> assign(:app_passwords, app_passwords)
     |> assign(:imap_settings, MailClientSettings.imap())
     |> assign(:smtp_settings, MailClientSettings.smtp())
     |> assign(:pop3_settings, MailClientSettings.pop3())
     |> assign(:new_token, nil)
     |> assign(:form_version, 0)
     |> assign(:form, app_password_form())}
  end

  @impl true
  def handle_event("create", %{"app_password" => params}, socket) do
    create_app_password(params, socket)
  end

  def handle_event("create", params, socket) do
    create_app_password(params, socket)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if recent_auth_valid?(socket) do
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
    else
      {:noreply, put_flash(socket, :error, recent_auth_required_message())}
    end
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  defp create_app_password(params, socket) do
    if recent_auth_valid?(socket) do
      user = socket.assigns.current_user
      name = params["name"]
      expires_option = params["expires_at"]

      expires_at = expires_at_from_option(expires_option)

      case Accounts.create_app_password(user.id, %{name: name, expires_at: expires_at}) do
        {:ok, app_password} ->
          app_passwords = Accounts.list_app_passwords(user.id)
          fresh_form = app_password_form()

          {:noreply,
           socket
           |> assign(:app_passwords, app_passwords)
           |> assign(:form, fresh_form)
           |> update(:form_version, &(&1 + 1))
           |> assign(:new_token, app_password.token)
           |> put_flash(:info, "App password created successfully")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:form, app_password_form(params))
           |> put_flash(:error, "Failed to create app password")}
      end
    else
      {:noreply,
       socket
       |> assign(:form, app_password_form(params))
       |> put_flash(:error, recent_auth_required_message())}
    end
  end

  defp recent_auth_valid?(socket) do
    socket.assigns
    |> Map.get(:user_recent_auth_at)
    |> UserAuth.recent_auth_valid?()
  end

  defp recent_auth_required_message do
    "Managing app passwords requires a recent login. Sign in again and retry."
  end

  defp app_password_form(params \\ %{}) do
    defaults = %{"name" => "", "expires_at" => "never"}

    defaults
    |> Map.merge(params)
    |> to_form(as: :app_password)
  end

  defp expires_at_from_option(expires_option) do
    case expires_option do
      "30_days" -> DateTime.utc_now() |> DateTime.add(30, :day)
      "90_days" -> DateTime.utc_now() |> DateTime.add(90, :day)
      "1_year" -> DateTime.utc_now() |> DateTime.add(365, :day)
      "never" -> nil
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.account_page
      title={gettext("App Passwords")}
      subtitle={gettext("Manage app-specific passwords for email clients")}
      sidebar_tab="security"
      current_user={@current_user}
    >
      <!-- Information Card -->
      <.card class="border border-base-300" body_class="p-4 sm:p-6">
        <:body>
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
        </:body>
      </.card>

      <div class="grid gap-6 lg:grid-cols-2">
        <!-- Create New App Password -->
        <.card class="border border-base-300" body_class="p-4 sm:p-6">
          <:body>
            <h2 class="card-title text-lg mb-4">Create App Password</h2>
            <.form id={"create-app-password-form-#{@form_version}"} for={@form} phx-submit="create">
              <div class="form-control">
                <.input
                  field={@form[:name]}
                  id={"app-password-name-#{@form_version}"}
                  type="text"
                  label="App name"
                  placeholder="e.g., Thunderbird on laptop"
                  required
                  maxlength="100"
                  autocomplete="off"
                />
                <label class="label">
                  <span class="label-text-alt text-xs">
                    Give it a name to remember which app uses this password
                  </span>
                </label>
              </div>

              <div class="form-control mt-4">
                <.input
                  field={@form[:expires_at]}
                  id={"app-password-expiration-#{@form_version}"}
                  type="select"
                  label="Expires"
                  options={[
                    {"Never", "never"},
                    {"30 days", "30_days"},
                    {"90 days", "90_days"},
                    {"1 year", "1_year"}
                  ]}
                />
                <label class="label">
                  <span class="label-text-alt text-xs">
                    Password will automatically stop working after this period
                  </span>
                </label>
              </div>

              <div class="card-actions mt-4">
                <.button type="submit" class="w-full">
                  <.icon name="hero-plus" class="w-4 h-4" /> Create Password
                </.button>
              </div>
            </.form>
          </:body>
        </.card>
        
    <!-- Usage Instructions -->
        <.card class="border border-base-300" body_class="p-4 sm:p-6">
          <:body>
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
          </:body>
        </.card>
      </div>
      
    <!-- Newly created password -->
      <%= if @new_token do %>
        <.card class="border border-success/40" body_class="p-4 sm:p-6">
          <:body>
            <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 class="text-lg font-bold flex items-center gap-2 text-success">
                  <.icon name="hero-check-circle" class="w-6 h-6" /> App Password Created
                </h2>
                <p class="mt-2 text-sm text-base-content/70">
                  This password will only be shown once. Copy it now before leaving this page.
                </p>
              </div>

              <.button variant="ghost" size="sm" class="self-start" phx-click="dismiss_token">
                <.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
              </.button>
            </div>

            <div class="alert alert-warning mt-1">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 flex-shrink-0" />
              <span class="text-sm">Save it in your password manager or client settings now.</span>
            </div>

            <div class="form-control mt-4">
              <label class="label">
                <span class="label-text text-sm font-semibold">Your app password</span>
              </label>
              <div class="join w-full">
                <div class="join-item flex-1 rounded-l-lg bg-base-200 p-4 text-center">
                  <code id="new-app-password-token" class="text-lg font-mono select-all break-all">
                    {@new_token}
                  </code>
                </div>
                <.button
                  type="button"
                  id="copy-new-app-password-token"
                  class="join-item h-auto px-4"
                  phx-hook="CopyToClipboard"
                  data-content={@new_token}
                  title="Copy app password"
                  aria-label="Copy app password"
                >
                  <.icon name="hero-clipboard-document" class="w-4 h-4" />
                  <span class="hidden sm:inline">Copy</span>
                </.button>
              </div>
            </div>

            <div class="bg-base-200 rounded-lg p-3 mt-4">
              <div class="flex items-center justify-between gap-3 mb-3">
                <p class="text-xs text-base-content/70 font-semibold">
                  Email client configuration:
                </p>
                <.button
                  type="button"
                  variant="ghost"
                  size="xs"
                  id="copy-email-client-configuration"
                  phx-hook="CopyToClipboard"
                  data-copy-target="email-client-configuration-copy-text"
                  title="Copy email client configuration"
                  aria-label="Copy email client configuration"
                >
                  <.icon name="hero-clipboard-document" class="w-3 h-3" /> Copy
                </.button>
              </div>
              <textarea id="email-client-configuration-copy-text" class="hidden" readonly><%= app_password_client_configuration(@current_user, @new_token, @imap_settings, @smtp_settings, @pop3_settings) %></textarea>
              <div class="text-xs text-base-content/60 space-y-3">
                <div>
                  <p class="font-semibold mb-1">IMAP (Recommended):</p>
                  <p>• Server: {@imap_settings.host}</p>
                  <p>
                    • Port: {@imap_settings.port} (IMAP with {MailClientSettings.security_label(
                      @imap_settings
                    )})
                  </p>
                </div>
                <div>
                  <p class="font-semibold mb-1">SMTP (Outgoing):</p>
                  <p>• Server: {@smtp_settings.host}</p>
                  <p>
                    • Port: {@smtp_settings.port} (SMTP with {MailClientSettings.security_label(
                      @smtp_settings
                    )})
                  </p>
                </div>
                <div>
                  <p class="font-semibold mb-1">POP3 (Alternative):</p>
                  <p>• Server: {@pop3_settings.host}</p>
                  <p>
                    • Port: {@pop3_settings.port} (POP3 with {MailClientSettings.security_label(
                      @pop3_settings
                    )})
                  </p>
                </div>
                <div class="pt-2 border-t border-base-300">
                  <p>• Username: {mail_client_username(@current_user)}</p>
                  <p>• Password: The app password shown above</p>
                </div>
              </div>
            </div>
          </:body>
          <:actions>
            <.button phx-click="dismiss_token">
              I saved it
            </.button>
          </:actions>
        </.card>
      <% end %>
      
    <!-- Existing App Passwords -->
      <.card class="border border-base-300" body_class="p-4 sm:p-6">
        <:body>
          <h2 class="card-title text-lg mb-4">Existing App Passwords</h2>

          <%= if @app_passwords == [] do %>
            <.empty_state
              icon="hero-key"
              title="No app passwords created yet"
              description="Create one above to connect your email client"
              size="sm"
            />
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
                        <.button
                          variant="ghost"
                          size="sm"
                          class="text-error"
                          phx-click="delete"
                          phx-value-id={app_password.id}
                          data-confirm="Delete this app password? Any apps using it will lose access."
                        >
                          <.icon name="hero-trash" class="w-4 h-4" /> Delete
                        </.button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </:body>
      </.card>
    </.account_page>
    """
  end

  defp app_password_client_configuration(user, token, imap_settings, smtp_settings, pop3_settings) do
    username = mail_client_username(user)

    [
      "Email client configuration",
      "",
      "Username: #{username}",
      "Password: #{token}",
      "",
      "IMAP (Recommended)",
      "Server: #{imap_settings.host}",
      "Port: #{imap_settings.port}",
      "Security: #{MailClientSettings.security_label(imap_settings)}",
      "",
      "SMTP (Outgoing)",
      "Server: #{smtp_settings.host}",
      "Port: #{smtp_settings.port}",
      "Security: #{MailClientSettings.security_label(smtp_settings)}",
      "",
      "POP3 (Alternative)",
      "Server: #{pop3_settings.host}",
      "Port: #{pop3_settings.port}",
      "Security: #{MailClientSettings.security_label(pop3_settings)}"
    ]
    |> Enum.join("\n")
  end

  defp mail_client_username(%{username: username}) when is_binary(username) and username != "" do
    username
  end

  defp mail_client_username(_), do: "Your elektrine username"
end
