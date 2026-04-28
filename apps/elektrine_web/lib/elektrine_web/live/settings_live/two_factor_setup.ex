defmodule ElektrineWeb.SettingsLive.TwoFactorSetup do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts
  import ElektrineWeb.Live.NotificationHelpers

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  def mount(params, session, socket) do
    user = socket.assigns.current_user

    if user.two_factor_enabled do
      {:ok, push_navigate(socket, to: ~p"/account/two_factor")}
    else
      # Force regeneration if requested or if no secret in session
      force_new = params["refresh"] == "true" || !session["two_factor_setup_secret"]

      if force_new do
        case Accounts.initiate_two_factor_setup(user) do
          {:ok, setup_data} ->
            qr_code_data_uri = generate_qr_data_uri(setup_data.provisioning_uri)

            {:ok,
             assign(socket,
               page_title: "Two-Factor Setup",
               secret: setup_data.secret,
               hashed_backup_codes: setup_data.hashed_backup_codes,
               backup_codes: setup_data.plain_backup_codes,
               provisioning_uri: setup_data.provisioning_uri,
               qr_code_data_uri: qr_code_data_uri,
               error: nil,
               submitting: false
             )}

          {:error, _} ->
            {:ok,
             socket
             |> put_flash(:error, "Failed to initialize two-factor authentication setup.")
             |> push_navigate(to: ~p"/account")}
        end
      else
        secret = session["two_factor_setup_secret"]
        plain_backup_codes = session["two_factor_setup_backup_codes_plain"]
        hashed_backup_codes = session["two_factor_setup_backup_codes_hashed"]
        provisioning_uri = Accounts.TwoFactor.generate_provisioning_uri(secret, user.username)
        qr_code_data_uri = generate_qr_data_uri(provisioning_uri)

        {:ok,
         assign(socket,
           page_title: "Two-Factor Setup",
           secret: secret,
           hashed_backup_codes: hashed_backup_codes,
           backup_codes: plain_backup_codes,
           provisioning_uri: provisioning_uri,
           qr_code_data_uri: qr_code_data_uri,
           error: nil,
           submitting: false
         )}
      end
    end
  end

  def render(assigns) do
    ~H"""
    <.account_page
      title="Set Up Two-Factor Authentication"
      subtitle="Secure your account with an authenticator app."
      sidebar_tab="security"
      current_user={@current_user}
    >
      <div class="space-y-4 sm:space-y-6">
        <div id="step1-card" class="card panel-card border border-base-300">
          <div class="card-body p-4 sm:p-6">
            <.section_header
              title="Install an authenticator app"
              description="Use any TOTP-compatible authenticator app on your phone or password manager."
            >
              <:actions>
                <span class="badge badge-outline">Step 1</span>
              </:actions>
            </.section_header>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
              <div class="rounded-lg bg-base-200/70 p-3 sm:p-4">
                <div class="flex items-center gap-3">
                  <.brand_icon name="google" class="w-8 h-8 shrink-0" />
                  <div>
                    <h3 class="font-medium text-sm sm:text-base">Google Authenticator</h3>
                    <p class="text-xs text-base-content/60">iOS & Android</p>
                  </div>
                </div>
              </div>

              <div class="rounded-lg bg-base-200/70 p-3 sm:p-4">
                <div class="flex items-center gap-3">
                  <.brand_icon name="authy" class="w-8 h-8 shrink-0" />
                  <div>
                    <h3 class="font-medium text-sm sm:text-base">Authy</h3>
                    <p class="text-xs text-base-content/60">iOS & Android</p>
                  </div>
                </div>
              </div>

              <div class="rounded-lg bg-base-200/70 p-3 sm:p-4">
                <div class="flex items-center gap-3">
                  <.brand_icon name="microsoft" class="w-8 h-8 shrink-0" />
                  <div>
                    <h3 class="font-medium text-sm sm:text-base">Microsoft Authenticator</h3>
                    <p class="text-xs text-base-content/60">iOS & Android</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div id="step2-card" class="card panel-card border border-base-300">
          <div class="card-body p-4 sm:p-6">
            <.section_header
              title="Scan the QR code"
              description="Open your authenticator app and add Elektrine as a new account."
            >
              <:actions>
                <span class="badge badge-outline">Step 2</span>
              </:actions>
            </.section_header>

            <div class="flex flex-col items-center my-4 sm:my-6">
              <div
                class="rounded-xl border border-base-300 bg-base-100 p-3 sm:p-4"
                style={"background-color: #{Elektrine.Theme.inverse_text_color()};"}
              >
                <%= if @qr_code_data_uri do %>
                  <img
                    src={@qr_code_data_uri}
                    alt="QR Code for 2FA setup"
                    class="w-40 h-40 sm:w-48 sm:h-48"
                  />
                <% else %>
                  <div class="w-40 h-40 sm:w-48 sm:h-48 flex items-center justify-center text-error">
                    <.icon name="hero-exclamation-triangle" class="w-12 h-12" />
                  </div>
                <% end %>
              </div>
              <.link
                href={~p"/account/two_factor/setup?refresh=true"}
                class="btn btn-ghost btn-sm mt-2"
              >
                <.icon name="hero-arrow-path" class="h-4 w-4 mr-1" /> Generate New QR Code
              </.link>

              <div class="rounded-lg border border-warning/20 bg-warning/10 p-4 mt-4 max-w-md flex gap-3">
                <.icon name="hero-exclamation-triangle" class="h-5 w-5 shrink-0" />
                <div>
                  <p class="text-sm font-medium">Getting "Invalid Code" errors?</p>
                  <p class="text-xs mt-1">
                    1. Delete any existing Elektrine entry from your authenticator app, then scan this QR code again.
                  </p>
                  <p class="text-xs mt-1">
                    2. Check your device's time is correct - TOTP codes are time-sensitive.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200/70 mt-4 max-w-md mx-auto rounded-lg">
                <input type="checkbox" class="checkbox" />
                <div class="collapse-title text-xs sm:text-sm font-medium">
                  Can't scan? Enter this code manually
                </div>
                <div class="collapse-content">
                  <div class="bg-base-200 rounded-lg p-3">
                    <div class="space-y-2 text-xs">
                      <div>
                        <span class="font-medium text-base-content/70">Secret:</span>
                        <div class="font-medium text-sm bg-base-200 p-2 rounded mt-1 break-all">
                          {Elektrine.Accounts.TwoFactor.secret_to_base32(@secret)}
                        </div>
                      </div>
                      <div>
                        <span class="font-medium text-base-content/70">Issuer:</span>
                        <span class="ml-2">Elektrine</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div id="step3-card" class="card panel-card border border-base-300">
          <div class="card-body p-4 sm:p-6">
            <.section_header
              title="Save your backup codes"
              description="These one-time codes can unlock your account if your authenticator is unavailable."
            >
              <:actions>
                <span class="badge badge-outline">Step 3</span>
              </:actions>
            </.section_header>

            <div class="rounded-lg border border-warning/20 bg-warning/10 p-4 mb-4 flex gap-3">
              <.icon name="hero-exclamation-triangle" class="w-6 h-6 shrink-0" />
              <div>
                <h3 class="font-semibold">Save these before continuing</h3>
                <div class="text-sm">
                  Store these codes in a safe place. You can use them to access your account if you lose your phone.
                </div>
              </div>
            </div>

            <div class="bg-base-200/70 rounded-box p-4">
              <div class="grid grid-cols-2 gap-3">
                <%= for code <- @backup_codes || [] do %>
                  <div class="badge badge-lg badge-outline font-medium p-4 w-full justify-center">
                    {code}
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div id="step4-card" class="card panel-card border border-base-300">
          <div class="card-body p-4 sm:p-6">
            <.section_header
              title="Verify your setup"
              description="Enter the current six-digit code to finish enabling two-factor authentication."
            >
              <:actions>
                <span class="badge badge-outline">Step 4</span>
              </:actions>
            </.section_header>

            <%= if @error do %>
              <div class="alert alert-error mb-4">
                <.icon name="hero-x-circle" class="w-6 h-6 shrink-0" />
                <span>{@error}</span>
              </div>
            <% end %>

            <.form for={%{}} as={:two_factor} phx-submit="enable_two_factor">
              <div class="form-control max-w-xs mx-auto">
                <label class="label">
                  <span class="label-text text-sm">
                    Enter the 6-digit code from your authenticator app
                  </span>
                </label>
                <input
                  id="code"
                  name="two_factor[code]"
                  type="text"
                  autocomplete="off"
                  required
                  class="input input-bordered w-full font-medium text-lg text-center"
                  placeholder="000000"
                  maxlength="6"
                  pattern="[0-9]{6}"
                  disabled={@submitting}
                />
              </div>

              <div class="card-actions justify-end mt-4 sm:mt-6">
                <button type="submit" class="btn btn-primary btn-sm sm:btn-md" disabled={@submitting}>
                  <%= if @submitting do %>
                    <.spinner size="sm" /> Verifying...
                  <% else %>
                    Enable Two-Factor Authentication
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </.account_page>
    """
  end

  def handle_event("enable_two_factor", %{"two_factor" => %{"code" => code}}, socket) do
    user = socket.assigns.current_user
    secret = socket.assigns.secret
    hashed_backup_codes = socket.assigns.hashed_backup_codes

    socket = assign(socket, :submitting, true)

    case Accounts.enable_two_factor(user, secret, hashed_backup_codes, code) do
      {:ok, _updated_user} ->
        {:noreply,
         socket
         |> notify_success("Two-factor authentication has been enabled successfully!",
           title: "2FA Enabled"
         )
         |> push_navigate(to: ~p"/account")}

      {:error, :invalid_totp_code} ->
        {:noreply,
         socket
         |> assign(:submitting, false)
         |> assign(:error, "Invalid authentication code. Please try again.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:submitting, false)
         |> assign(:error, "Failed to enable two-factor authentication. Please try again.")}
    end
  end

  defp generate_qr_data_uri(provisioning_uri) do
    case Accounts.TwoFactor.generate_qr_code_data_uri(provisioning_uri) do
      {:ok, data_uri} -> data_uri
      {:error, _} -> nil
    end
  end
end
