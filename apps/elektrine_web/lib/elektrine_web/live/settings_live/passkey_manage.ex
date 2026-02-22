defmodule ElektrineWeb.SettingsLive.PasskeyManage do
  @moduledoc """
  LiveView for managing WebAuthn passkeys.
  """
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.Passkeys
  alias Elektrine.Accounts.PasskeyCredential

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    passkeys = Passkeys.list_user_passkeys(user)
    max_passkeys = PasskeyCredential.max_passkeys_per_user()

    {:ok,
     assign(socket,
       page_title: "Passkeys",
       passkeys: passkeys,
       passkey_count: length(passkeys),
       max_passkeys: max_passkeys,
       registering: false,
       renaming_id: nil,
       error: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <div class="text-center mb-8">
        <h1 class="text-3xl font-bold mb-2">{gettext("Passkeys")}</h1>
        <p class="text-base-content/70">
          {gettext("Sign in without a password using your device's biometrics or security key")}
        </p>
      </div>

      <div id="passkey-manage-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
        <div class="card-body">
          <div class="flex items-center justify-between mb-6">
            <div class="flex items-center gap-4">
              <.icon name="hero-finger-print" class="w-12 h-12 text-primary" />
              <div>
                <h2 class="text-xl font-bold">{gettext("Your Passkeys")}</h2>
                <p class="text-base-content/70">
                  {@passkey_count} / {@max_passkeys} {gettext("registered")}
                </p>
              </div>
            </div>

            <%= if @passkey_count < @max_passkeys do %>
              <button
                id="add-passkey-btn"
                phx-hook="PasskeyRegister"
                phx-click="start_registration"
                disabled={@registering}
                class="btn btn-primary"
              >
                <%= if @registering do %>
                  <span class="loading loading-spinner loading-sm"></span>
                  {gettext("Registering...")}
                <% else %>
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {gettext("Add Passkey")}
                <% end %>
              </button>
            <% else %>
              <div class="tooltip" data-tip={gettext("Maximum passkeys reached")}>
                <button class="btn btn-primary" disabled>
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {gettext("Add Passkey")}
                </button>
              </div>
            <% end %>
          </div>

          <%= if @error do %>
            <div class="alert alert-error mb-4">
              <.icon name="hero-exclamation-circle" class="w-5 h-5" />
              <span>{@error}</span>
              <button type="button" phx-click="clear_error" class="btn btn-ghost btn-xs">
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          <% end %>

          <div class="divider"></div>

          <%= if @passkeys == [] do %>
            <div class="text-center py-8">
              <.icon name="hero-key" class="w-16 h-16 mx-auto text-base-content/30 mb-4" />
              <h3 class="text-lg font-semibold mb-2">{gettext("No passkeys registered")}</h3>
              <p class="text-base-content/70 max-w-md mx-auto">
                {gettext(
                  "Add a passkey to sign in faster and more securely using your device's biometrics or a security key."
                )}
              </p>
            </div>
          <% else %>
            <div class="space-y-3">
              <%= for passkey <- @passkeys do %>
                <div class="flex items-center justify-between p-4 bg-base-200 rounded-lg">
                  <div class="flex items-center gap-3">
                    <.icon name={passkey_icon(passkey)} class="w-8 h-8 text-base-content/70" />
                    <div>
                      <%= if @renaming_id == passkey.id do %>
                        <form phx-submit="save_rename" class="flex items-center gap-2">
                          <input
                            type="text"
                            name="name"
                            value={passkey.name}
                            class="input input-sm input-bordered w-40"
                            maxlength="100"
                            autofocus
                          />
                          <input type="hidden" name="passkey_id" value={passkey.id} />
                          <button type="submit" class="btn btn-ghost btn-xs">
                            <.icon name="hero-check" class="w-4 h-4 text-success" />
                          </button>
                          <button type="button" phx-click="cancel_rename" class="btn btn-ghost btn-xs">
                            <.icon name="hero-x-mark" class="w-4 h-4" />
                          </button>
                        </form>
                      <% else %>
                        <p class="font-medium">{passkey.name}</p>
                        <p class="text-xs text-base-content/50">
                          {gettext("Added")} {format_date(passkey.inserted_at)}
                          <%= if passkey.last_used_at do %>
                            - {gettext("Last used")} {format_date(passkey.last_used_at)}
                          <% end %>
                        </p>
                      <% end %>
                    </div>
                  </div>
                  <div class="flex items-center gap-2">
                    <%= if @renaming_id != passkey.id do %>
                      <button
                        type="button"
                        phx-click="start_rename"
                        phx-value-id={passkey.id}
                        class="btn btn-ghost btn-sm"
                        title={gettext("Rename")}
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="delete_passkey"
                        phx-value-id={passkey.id}
                        data-confirm={gettext("Are you sure you want to delete this passkey?")}
                        class="btn btn-ghost btn-sm text-error"
                        title={gettext("Delete")}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <div class="divider"></div>

          <div class="space-y-4">
            <h3 class="text-lg font-semibold">{gettext("About Passkeys")}</h3>
            <div class="prose prose-sm max-w-none text-base-content/70">
              <ul class="space-y-2">
                <li class="flex items-start gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-success shrink-0 mt-0.5" />
                  <span>
                    {gettext(
                      "Passkeys are more secure than passwords - they can't be phished or stolen in data breaches"
                    )}
                  </span>
                </li>
                <li class="flex items-start gap-2">
                  <.icon name="hero-bolt" class="w-5 h-5 text-warning shrink-0 mt-0.5" />
                  <span>
                    {gettext(
                      "Sign in quickly using Face ID, Touch ID, Windows Hello, or a security key"
                    )}
                  </span>
                </li>
                <li class="flex items-start gap-2">
                  <.icon name="hero-device-phone-mobile" class="w-5 h-5 text-info shrink-0 mt-0.5" />
                  <span>{gettext("Register passkeys on multiple devices for backup access")}</span>
                </li>
                <li class="flex items-start gap-2">
                  <.icon name="hero-check-badge" class="w-5 h-5 text-primary shrink-0 mt-0.5" />
                  <span>
                    {gettext("Passkey login bypasses TOTP 2FA since it's already multi-factor")}
                  </span>
                </li>
              </ul>
            </div>
          </div>

          <div class="divider"></div>

          <div class="card-actions">
            <.link href={~p"/account"} class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back to account settings")}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("start_registration", _params, socket) do
    user = socket.assigns.current_user
    host = get_request_host(socket)

    case Passkeys.generate_registration_challenge(user, host: host) do
      {:ok, challenge_data} ->
        # Store challenge in socket for verification
        socket =
          socket
          |> assign(:registering, true)
          |> assign(:registration_challenge, challenge_data.challenge)
          |> push_event("passkey_registration_challenge", %{
            challenge_b64: challenge_data.challenge_b64,
            rp_id: challenge_data.rp_id,
            rp_name: challenge_data.rp_name,
            user_id: challenge_data.user_id,
            user_name: challenge_data.user_name,
            user_display_name: challenge_data.user_display_name,
            timeout: challenge_data.timeout,
            attestation: challenge_data.attestation,
            authenticator_selection: challenge_data.authenticator_selection,
            exclude_credentials: challenge_data.exclude_credentials,
            pub_key_cred_params: challenge_data.pub_key_cred_params,
            suggested_name: "Passkey #{socket.assigns.passkey_count + 1}"
          })

        {:noreply, socket}

      {:error, :passkey_limit_reached} ->
        {:noreply,
         assign(socket, :error, gettext("You have reached the maximum number of passkeys"))}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Failed to start passkey registration"))}
    end
  end

  @impl true
  def handle_event(
        "passkey_registration_response",
        %{"attestation" => attestation, "name" => name},
        socket
      ) do
    user = socket.assigns.current_user
    challenge = socket.assigns[:registration_challenge]

    if is_nil(challenge) do
      {:noreply,
       assign(socket, error: gettext("Registration session expired. Please try again."))}
    else
      # Get request metadata for auditing
      metadata = %{
        name: name,
        ip: nil,
        user_agent: nil
      }

      case Passkeys.complete_registration(user, challenge, attestation, metadata) do
        {:ok, _credential} ->
          passkeys = Passkeys.list_user_passkeys(user)

          socket =
            socket
            |> assign(:passkeys, passkeys)
            |> assign(:passkey_count, length(passkeys))
            |> assign(:registering, false)
            |> assign(:registration_challenge, nil)
            |> assign(:error, nil)
            |> put_flash(:info, gettext("Passkey registered successfully"))

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:registering, false)
           |> assign(:registration_challenge, nil)
           |> assign(:error, gettext("Failed to register passkey. Please try again."))}
      end
    end
  end

  @impl true
  def handle_event("passkey_registration_error", %{"error" => error}, socket) do
    {:noreply,
     socket
     |> assign(:registering, false)
     |> assign(:registration_challenge, nil)
     |> assign(:error, error)}
  end

  @impl true
  def handle_event("start_rename", %{"id" => id}, socket) do
    {:noreply, assign(socket, :renaming_id, String.to_integer(id))}
  end

  @impl true
  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :renaming_id, nil)}
  end

  @impl true
  def handle_event("save_rename", %{"passkey_id" => id, "name" => name}, socket) do
    user = socket.assigns.current_user
    passkey_id = String.to_integer(id)

    case Passkeys.rename_passkey(user, passkey_id, name) do
      {:ok, _passkey} ->
        passkeys = Passkeys.list_user_passkeys(user)

        {:noreply,
         socket
         |> assign(:passkeys, passkeys)
         |> assign(:renaming_id, nil)
         |> put_flash(:info, gettext("Passkey renamed"))}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Failed to rename passkey"))}
    end
  end

  @impl true
  def handle_event("delete_passkey", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    passkey_id = String.to_integer(id)

    case Passkeys.delete_passkey(user, passkey_id) do
      {:ok, _} ->
        passkeys = Passkeys.list_user_passkeys(user)

        {:noreply,
         socket
         |> assign(:passkeys, passkeys)
         |> assign(:passkey_count, length(passkeys))
         |> put_flash(:info, gettext("Passkey deleted"))}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Failed to delete passkey"))}
    end
  end

  @impl true
  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  # Helper functions

  defp passkey_icon(passkey) do
    cond do
      "internal" in (passkey.transports || []) -> "hero-device-phone-mobile"
      "usb" in (passkey.transports || []) -> "hero-key"
      "nfc" in (passkey.transports || []) -> "hero-signal"
      "ble" in (passkey.transports || []) -> "hero-signal"
      "hybrid" in (passkey.transports || []) -> "hero-device-tablet"
      true -> "hero-finger-print"
    end
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp get_request_host(socket) do
    case socket.host_uri do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end
end
