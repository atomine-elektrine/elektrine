defmodule ElektrineWeb.SettingsLive.MasterPassword do
  @moduledoc """
  Account-password vault setup / unlock / recovery.

  All crypto happens in the browser (the `VaultManager` hook). This LiveView only
  stores and returns the wrapped Master Data Key blobs via `Elektrine.Vault`; it
  never sees the recovery code or the key itself. It verifies the account
  password before accepting a new account-password wrapper so a typo cannot
  create an unlock secret that differs from the user's login password.
  """
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  alias Elektrine.Accounts
  alias Elektrine.Vault
  alias ElektrineWeb.Platform.Integrations

  def mount(_params, _session, socket) do
    {:ok, assign_vault(socket)}
  end

  defp assign_vault(socket) do
    master = Vault.get(socket.assigns.current_user.id)

    socket
    |> assign(:page_title, "Encrypted Data")
    |> assign(:vault_configured, not is_nil(master))
    |> assign(:wrapped_dek, master && master.wrapped_dek)
    |> assign(:wrapped_dek_recovery, master && master.wrapped_dek_recovery)
  end

  def handle_event("setup_master", %{"master" => params}, socket) do
    with :ok <- verify_current_password(socket.assigns.current_user, params["current_password"]),
         {:ok, dek} <- decode(params["wrapped_dek"]),
         {:ok, rec} <- decode(params["wrapped_dek_recovery"]),
         {:ok, _} <-
           Vault.setup(socket.assigns.current_user.id, %{
             "wrapped_dek" => dek,
             "wrapped_dek_recovery" => rec
           }) do
      {:noreply,
       socket
       |> assign_vault()
       |> put_flash(
         :info,
         "Account password now unlocks encrypted data. Keep your recovery code safe."
       )}
    else
      {:error, :invalid_password} ->
        {:noreply, put_flash(socket, :error, "Current account password is incorrect.")}

      {:error, :already_configured} ->
        {:noreply, put_flash(socket, :error, "Encrypted data is already configured.")}

      {:error, :missing_payload} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Encrypted data was not generated in this browser. Use the setup button and try again."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not set up encrypted data. Try again.")}
    end
  end

  def handle_event("rotate_master", %{"master" => params}, socket) do
    with :ok <- verify_current_password(socket.assigns.current_user, params["current_password"]),
         {:ok, dek} <- decode(params["wrapped_dek"]),
         {:ok, rec} <- decode(params["wrapped_dek_recovery"]),
         {:ok, _} <-
           Vault.rotate(socket.assigns.current_user.id, %{
             "wrapped_dek" => dek,
             "wrapped_dek_recovery" => rec
           }) do
      {:noreply,
       socket
       |> assign_vault()
       |> put_flash(:info, "Encrypted data now unlocks with your current account password.")}
    else
      {:error, :invalid_password} ->
        {:noreply, put_flash(socket, :error, "Current account password is incorrect.")}

      {:error, :missing_payload} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Encrypted data was not generated in this browser. Use the recovery button and try again."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update encrypted data access.")}
    end
  end

  def handle_event("reset_master", _params, socket) do
    user_id = socket.assigns.current_user.id
    {:ok, _} = Vault.reset(user_id)
    _ = Integrations.reset_private_mailbox_storage(user_id)

    {:noreply,
     socket
     |> assign_vault()
     |> put_flash(
       :info,
       "Encrypted data reset. Private mailbox storage was cleared so you can set it up again with your current account password."
     )}
  end

  defp verify_current_password(user, password) when is_binary(password) do
    case Accounts.verify_user_password(user, password) do
      {:ok, _user} -> :ok
      _ -> {:error, :invalid_password}
    end
  end

  defp verify_current_password(_user, _password), do: {:error, :invalid_password}

  defp decode(json) when is_binary(json) do
    if Elektrine.Strings.present?(json) do
      Jason.decode(json)
    else
      {:error, :missing_payload}
    end
  end

  defp decode(_), do: {:error, :missing_payload}

  def render(assigns) do
    ~H"""
    <.account_page
      title="Encrypted Data"
      subtitle="Your account password unlocks Nerve, Kairo, and private email in this browser."
      sidebar_tab="security"
      current_user={@current_user}
    >
      <div
        id="vault-manager"
        phx-hook="VaultManager"
        data-vault-configured={to_string(@vault_configured)}
        data-vault-wrapped-dek={@wrapped_dek && Jason.encode!(@wrapped_dek)}
        data-vault-wrapped-dek-recovery={
          @wrapped_dek_recovery && Jason.encode!(@wrapped_dek_recovery)
        }
        data-vault-secret-mode="account_password"
        class="space-y-6"
      >
        <%= if @vault_configured do %>
          <div class="surface-subtle rounded-box p-4 sm:p-5">
            <h2 class="text-base font-semibold text-base-content">How this works</h2>
            <div class="mt-3 grid gap-3 text-sm text-base-content/70 md:grid-cols-3">
              <div class="surface-muted rounded-lg p-3">
                <p class="font-medium text-base-content">Account password</p>
                <p class="mt-1">Signs you in and unlocks encrypted Elektrine data in this browser.</p>
              </div>
              <div class="surface-muted rounded-lg p-3">
                <p class="font-medium text-base-content">Browser-only unlock</p>
                <p class="mt-1">
                  The raw encryption key stays in this tab/session and is not sent to the server.
                </p>
              </div>
              <div class="surface-muted rounded-lg p-3">
                <p class="font-medium text-base-content">Recovery code</p>
                <p class="mt-1">
                  Lets you recover encrypted data after an account-password reset or lost password.
                </p>
              </div>
            </div>
          </div>

          <.card body_class="p-4 sm:p-6">
            <:body>
              <.section_header
                title="Unlock with account password"
                description="Use your account password. It unwraps the encryption key in this browser and is not sent from this page during unlock."
              >
                <:actions>
                  <span
                    class="badge badge-outline"
                    data-vault-status
                    data-locked-label="Locked"
                    data-unlocked-label="Unlocked"
                  >
                    Locked
                  </span>
                </:actions>
              </.section_header>

              <div class="mt-4 space-y-3" data-vault-locked-section>
                <input
                  type="password"
                  class="input input-bordered w-full"
                  placeholder="Account password"
                  autocomplete="current-password"
                  data-vault-unlock-input
                />
                <.button type="button" size="sm" data-vault-unlock>
                  Unlock
                </.button>
                <p class="text-xs text-base-content/60">
                  Reset your account password or lost access? Use the recovery section below to re-link encrypted data.
                </p>
                <p class="text-xs text-error" data-vault-error></p>
              </div>

              <div class="mt-4 hidden" data-vault-unlocked-section>
                <.button type="button" variant="default" outline size="sm" data-vault-lock>
                  Lock now
                </.button>
              </div>
            </:body>
          </.card>

          <.card body_class="p-4 sm:p-6">
            <:body>
              <.section_header
                title="Recover encrypted data"
                description="If your account password was reset or encrypted data no longer unlocks, use your recovery code to rewrap it to your current password."
              />

              <form
                id="vault-recovery-form"
                phx-submit="rotate_master"
                data-vault-recovery-form
                class="mt-4 space-y-3"
              >
                <input
                  type="text"
                  class="input input-bordered w-full font-mono"
                  placeholder="Recovery code"
                  autocomplete="off"
                  spellcheck="false"
                  data-vault-recovery-code
                />
                <input
                  type="password"
                  class="input input-bordered w-full"
                  name="master[current_password]"
                  placeholder="Current account password"
                  autocomplete="current-password"
                  data-vault-recovery-new-input
                />
                <input
                  type="hidden"
                  name="master[wrapped_dek]"
                  data-vault-recovery-wrapped-dek-input
                />
                <input
                  type="hidden"
                  name="master[wrapped_dek_recovery]"
                  data-vault-recovery-wrapped-dek-recovery-input
                />
                <p class="text-xs text-error" data-vault-recovery-error></p>
                <.button type="button" size="sm" data-vault-recovery>
                  Recover and create new code
                </.button>
              </form>

              <div
                class="mt-4 hidden rounded-box border border-warning/40 bg-warning/5 p-4"
                data-vault-recovery-new-panel
              >
                <p class="text-sm font-semibold">Save this new recovery code</p>
                <p class="mt-1 text-xs text-base-content/70">
                  Your old recovery code stops working after this update. This new code is shown once.
                </p>
                <code
                  class="mt-2 block break-all rounded-lg bg-base-200 p-3 font-mono text-sm"
                  data-vault-recovery-new-output
                >
                </code>
                <.button
                  type="button"
                  size="sm"
                  class="mt-3"
                  data-vault-recovery-finish
                >
                  I've saved it - update encrypted data
                </.button>
              </div>
            </:body>
          </.card>

          <.card class="border border-error/30" body_class="p-4 sm:p-6">
            <:body>
              <.section_header
                title="Reset encrypted data"
                description="Only use this if you lost the recovery code and cannot unlock with the password that originally protected this data."
              />
              <div class="mt-4 rounded-box border border-error/30 bg-error/5 p-4 text-sm text-base-content/70">
                <p class="font-medium text-error">Permanent consequence</p>
                <p class="mt-1">
                  Existing encrypted Nerve entries, Kairo encrypted notes, and private email data become unreadable. Your Elektrine account is not deleted.
                </p>
              </div>
              <label class="mt-4 block text-xs font-semibold uppercase tracking-wide text-base-content/70">
                Type RESET ENCRYPTED DATA to enable reset
              </label>
              <input
                type="text"
                class="input input-bordered mt-2 w-full"
                autocomplete="off"
                data-vault-reset-confirm
              />
              <.button
                type="button"
                variant="error"
                outline
                size="sm"
                class="mt-3"
                phx-click="reset_master"
                data-confirm="Reset encrypted data? Everything encrypted under this key becomes permanently unreadable."
                disabled
                data-vault-reset-button
              >
                Reset encrypted data
              </.button>
            </:body>
          </.card>
        <% else %>
          <div class="surface-subtle rounded-box p-4 sm:p-5">
            <h2 class="text-base font-semibold text-base-content">Before you start</h2>
            <ul class="mt-3 space-y-2 text-sm text-base-content/70">
              <li>Use your current account password. No separate Nerve password is needed.</li>
              <li>Elektrine verifies your account password before saving the encrypted wrapper.</li>
              <li>You will receive one recovery code. Save it somewhere outside Elektrine.</li>
              <li>
                If your account password is reset, the recovery code keeps existing encrypted data accessible.
              </li>
            </ul>
          </div>

          <.card body_class="p-4 sm:p-6">
            <:body>
              <.section_header
                title="Set up account-password encryption"
                description="Enter your current account password once. The browser uses it to wrap the encryption key, and the server verifies it before saving."
              />

              <form
                id="vault-setup-form"
                phx-submit="setup_master"
                data-vault-setup-form
                class="mt-4 space-y-3"
              >
                <input
                  type="password"
                  class="input input-bordered w-full"
                  name="master[current_password]"
                  placeholder="Current account password"
                  autocomplete="current-password"
                  data-vault-setup-input
                />
                <input type="hidden" name="master[wrapped_dek]" data-vault-wrapped-dek-input />
                <input
                  type="hidden"
                  name="master[wrapped_dek_recovery]"
                  data-vault-wrapped-dek-recovery-input
                />
                <p class="text-xs text-error" data-vault-error></p>
                <.button type="button" size="sm" data-vault-setup>
                  Set up encryption
                </.button>
              </form>

              <div
                class="mt-4 hidden rounded-box border border-warning/40 bg-warning/5 p-4"
                data-vault-recovery-panel
              >
                <p class="text-sm font-semibold">Save your recovery code</p>
                <p class="mt-1 text-xs text-base-content/70">
                  This is the only way to keep encrypted data accessible if your account password is reset. It is shown once.
                </p>
                <code
                  class="mt-2 block break-all rounded-lg bg-base-200 p-3 font-mono text-sm"
                  data-vault-recovery-output
                >
                </code>
                <.button type="button" size="sm" class="mt-3" data-vault-setup-finish>
                  I've saved it - finish
                </.button>
              </div>
            </:body>
          </.card>
        <% end %>
      </div>
    </.account_page>
    """
  end
end
