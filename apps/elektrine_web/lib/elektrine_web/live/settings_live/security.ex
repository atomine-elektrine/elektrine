defmodule ElektrineWeb.SettingsLive.Security do
  @moduledoc """
  Master password setup / unlock / recovery.

  All crypto happens in the browser (the `VaultManager` hook). This LiveView only
  stores and returns the wrapped Master Data Key blobs via `Elektrine.Vault`; it
  never sees the passphrase, recovery code, or the key itself.
  """
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  alias Elektrine.Vault

  def mount(_params, _session, socket) do
    {:ok, assign_vault(socket)}
  end

  defp assign_vault(socket) do
    master = Vault.get(socket.assigns.current_user.id)

    socket
    |> assign(:page_title, "Master Password")
    |> assign(:vault_configured, not is_nil(master))
    |> assign(:wrapped_dek, master && master.wrapped_dek)
  end

  def handle_event("setup_master", %{"master" => params}, socket) do
    with {:ok, dek} <- decode(params["wrapped_dek"]),
         {:ok, rec} <- decode(params["wrapped_dek_recovery"]),
         {:ok, _} <-
           Vault.setup(socket.assigns.current_user.id, %{
             "wrapped_dek" => dek,
             "wrapped_dek_recovery" => rec
           }) do
      {:noreply,
       socket
       |> assign_vault()
       |> put_flash(:info, "Master password set. Keep your recovery code safe.")}
    else
      {:error, :already_configured} ->
        {:noreply, put_flash(socket, :error, "A master password is already set.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not set master password. Try again.")}
    end
  end

  def handle_event("rotate_master", %{"master" => params}, socket) do
    with {:ok, dek} <- decode(params["wrapped_dek"]),
         {:ok, rec} <- decode(params["wrapped_dek_recovery"]),
         {:ok, _} <-
           Vault.rotate(socket.assigns.current_user.id, %{
             "wrapped_dek" => dek,
             "wrapped_dek_recovery" => rec
           }) do
      {:noreply, socket |> assign_vault() |> put_flash(:info, "Master password updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update master password.")}
    end
  end

  def handle_event("reset_master", _params, socket) do
    {:ok, _} = Vault.reset(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign_vault()
     |> put_flash(
       :info,
       "Master password reset. Anything that was encrypted under it can no longer be decrypted."
     )}
  end

  defp decode(json) when is_binary(json), do: Jason.decode(json)
  defp decode(_), do: :error

  def render(assigns) do
    ~H"""
    <.account_page
      title="Master Password"
      subtitle="One zero-knowledge passphrase that unlocks Nerve, Kairo, and private email. The server never sees it."
      sidebar_tab="security"
      current_user={@current_user}
    >
      <div
        id="vault-manager"
        phx-hook="VaultManager"
        data-vault-configured={to_string(@vault_configured)}
        data-vault-wrapped-dek={@wrapped_dek && Jason.encode!(@wrapped_dek)}
        class="space-y-6"
      >
        <%= if @vault_configured do %>
          <div class="card panel-card border border-base-300">
            <div class="card-body p-4 sm:p-6">
              <.section_header
                title="Master password"
                description="Unlock once per browser session to use your encrypted data. It locks automatically when you close the tab."
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
                  placeholder="Master passphrase"
                  autocomplete="current-password"
                  data-vault-unlock-input
                />
                <button type="button" class="btn btn-primary btn-sm" data-vault-unlock>
                  Unlock
                </button>
                <p class="text-xs text-error" data-vault-error></p>
              </div>

              <div class="mt-4 hidden" data-vault-unlocked-section>
                <button type="button" class="btn btn-outline btn-sm" data-vault-lock>
                  Lock now
                </button>
              </div>
            </div>
          </div>

          <div class="card panel-card border border-error/30">
            <div class="card-body p-4 sm:p-6">
              <.section_header
                title="Reset master password"
                description="If you've lost both your passphrase and recovery code, reset to start over. This permanently discards access to everything encrypted under the current key."
              />
              <button
                type="button"
                phx-click="reset_master"
                data-confirm="Reset the master password? Everything encrypted under it becomes permanently unreadable."
                class="btn btn-error btn-outline btn-sm mt-3"
              >
                Reset
              </button>
            </div>
          </div>
        <% else %>
          <div class="card panel-card border border-base-300">
            <div class="card-body p-4 sm:p-6">
              <.section_header
                title="Set a master password"
                description="Choose a strong passphrase that is different from your login password. We can never recover it for you — you'll get a one-time recovery code."
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
                  placeholder="Master passphrase (14+ characters)"
                  autocomplete="new-password"
                  data-vault-setup-input
                />
                <input
                  type="password"
                  class="input input-bordered w-full"
                  placeholder="Confirm passphrase"
                  autocomplete="new-password"
                  data-vault-setup-confirm
                />
                <input type="hidden" name="master[wrapped_dek]" data-vault-wrapped-dek-input />
                <input
                  type="hidden"
                  name="master[wrapped_dek_recovery]"
                  data-vault-wrapped-dek-recovery-input
                />
                <p class="text-xs text-error" data-vault-error></p>
                <button type="button" class="btn btn-primary btn-sm" data-vault-setup>
                  Create master password
                </button>
              </form>

              <div
                class="mt-4 hidden rounded-box border border-warning/40 bg-warning/5 p-4"
                data-vault-recovery-panel
              >
                <p class="text-sm font-semibold">Save your recovery code</p>
                <p class="mt-1 text-xs text-base-content/70">
                  This is the only way to regain access if you forget your passphrase. It is shown once.
                </p>
                <code
                  class="mt-2 block break-all rounded bg-base-200 p-3 font-mono text-sm"
                  data-vault-recovery-output
                >
                </code>
                <button type="button" class="btn btn-primary btn-sm mt-3" data-vault-setup-finish>
                  I've saved it — finish
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </.account_page>
    """
  end
end
