defmodule ElektrineWeb.SettingsLive.TwoFactorManage do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.two_factor_enabled do
      backup_codes_count = length(user.two_factor_backup_codes || [])

      {:ok,
       assign(socket,
         page_title: "Two-Factor Authentication",
         backup_codes_count: backup_codes_count
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/account/two_factor/setup")}
    end
  end

  def render(assigns) do
    ~H"""
    <.account_page
      title="Two-Factor Authentication"
      subtitle="Your account is protected with an authenticator app and backup codes."
      sidebar_tab="security"
      current_user={@current_user}
    >
      <div id="2fa-manage-card" class="card panel-card border border-base-300">
        <div class="card-body">
          <.section_header
            title="Two-factor is enabled"
            description="Your account requires an authenticator code or backup code after password login."
          >
            <:actions>
              <span class="badge badge-success badge-outline">Enabled</span>
            </:actions>
          </.section_header>

          <div class="mt-6 space-y-6">
            <div class="rounded-lg bg-base-200/70 p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-key" class="w-5 h-5 shrink-0 text-base-content/60 mt-0.5" />
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold">Backup Codes</h3>
                  <p class="mt-1 text-sm text-base-content/70">
                    You have
                    <span class="font-semibold text-base-content">{@backup_codes_count}</span>
                    backup codes remaining. Generate a new set if these have been exposed or are running low.
                  </p>
                </div>
                <button
                  type="button"
                  data-open-modal="regenerate_modal"
                  class="btn btn-primary btn-sm shrink-0"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" /> Generate Codes
                </button>
              </div>
            </div>

            <div class="rounded-lg border border-error/20 bg-error/5 p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-shield-exclamation" class="w-5 h-5 shrink-0 text-error mt-0.5" />
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold text-error">Disable Two-Factor Authentication</h3>
                  <p class="mt-1 text-sm text-base-content/70">
                    Disabling 2FA will make your account less secure. You need your current password and an authenticator app code to confirm.
                  </p>
                </div>
                <button
                  type="button"
                  data-open-modal="disable_modal"
                  class="btn btn-ghost btn-sm text-error shrink-0"
                >
                  Disable 2FA
                </button>
              </div>
            </div>
          </div>

          <div class="mt-6 space-y-4">
            <h3 class="text-lg font-semibold">About Two-Factor Authentication</h3>
            <div class="prose prose-sm max-w-none text-base-content/70">
              <ul class="space-y-2">
                <li class="flex items-start gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-success shrink-0 mt-0.5" />
                  <span>
                    Authenticator codes protect your account even if your password is compromised.
                  </span>
                </li>
                <li class="flex items-start gap-2">
                  <.icon name="hero-document-text" class="w-5 h-5 text-warning shrink-0 mt-0.5" />
                  <span>
                    Backup codes are single-use. Store them somewhere private and recoverable.
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>

      <dialog id="regenerate_modal" class="modal">
        <div class="modal-box modal-surface max-w-md w-full mx-4">
          <h3 class="font-semibold text-lg mb-2">Generate New Backup Codes</h3>
          <p class="text-sm text-base-content/70 mb-4 break-words">
            This will replace your existing backup codes. Make sure to save the new codes in a safe place.
          </p>

          <.form for={%{}} as={:two_factor} action={~p"/account/two_factor/regenerate"}>
            <div>
              <label class="label">
                <span class="label-text">Authenticator App Code</span>
              </label>
              <input
                id="regenerate_code"
                name="two_factor[code]"
                type="text"
                autocomplete="off"
                required
                class="input input-bordered font-medium text-center w-full"
                placeholder="000000"
                maxlength="6"
                pattern="[0-9]{6}"
              />
            </div>

            <div class="modal-action">
              <button
                type="button"
                data-close-modal="regenerate_modal"
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">
                Generate New Codes
              </button>
            </div>
          </.form>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>close</button>
        </form>
      </dialog>

      <dialog id="disable_modal" class="modal">
        <div class="modal-box modal-surface max-w-md w-full mx-4">
          <h3 class="font-semibold text-lg mb-2 text-error">Disable Two-Factor Authentication</h3>
          <p class="text-sm text-base-content/70 mb-4 break-words">
            Are you sure you want to disable 2FA? This will make your account less secure.
          </p>

          <.form for={%{}} as={:two_factor} action={~p"/account/two_factor/disable"}>
            <div class="mb-4">
              <label class="label">
                <span class="label-text">Current Password</span>
              </label>
              <input
                id="current_password"
                name="two_factor[current_password]"
                type="password"
                required
                class="input input-bordered w-full"
              />
            </div>

            <div>
              <label class="label">
                <span class="label-text">Authenticator App Code</span>
              </label>
              <input
                id="disable_code"
                name="two_factor[code]"
                type="text"
                autocomplete="off"
                required
                class="input input-bordered font-medium text-center w-full"
                placeholder="000000"
                maxlength="6"
                pattern="[0-9]{6}"
              />
              <div class="label">
                <span class="label-text-alt text-warning">
                  Authenticator app only - backup codes won't work
                </span>
              </div>
            </div>

            <div class="modal-action">
              <button
                type="button"
                data-close-modal="disable_modal"
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-secondary">
                Disable 2FA
              </button>
            </div>
          </.form>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>close</button>
        </form>
      </dialog>
    </.account_page>
    """
  end
end
