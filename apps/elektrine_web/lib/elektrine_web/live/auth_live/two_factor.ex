defmodule ElektrineWeb.AuthLive.TwoFactor do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Two-Factor Authentication")}
  end

  def render(assigns) do
    ~H"""
    <div id="two-factor-card" class="card panel-card border border-base-300 max-w-md mx-auto">
      <div class="card-body p-6">
        <div class="mb-6 text-center">
          <div class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10">
            <.icon name="hero-shield-check" class="h-6 w-6 text-primary" />
          </div>
          <h1 class="text-2xl font-semibold">Two-Factor Authentication</h1>
          <p class="mt-2 text-sm text-base-content/70">
            Enter the code from your authenticator app or one of your backup codes.
          </p>
        </div>

        <.form for={%{}} as={:two_factor} action={~p"/two_factor"}>
          <div>
            <label class="label">
              <span class="label-text">Authentication Code</span>
            </label>
            <input
              id="code"
              name="two_factor[code]"
              type="text"
              autocomplete="off"
              autofocus
              required
              class="input input-bordered font-medium text-2xl text-center tracking-widest w-full"
              placeholder="000000"
              maxlength="8"
              pattern="[0-9A-Z]{6,8}"
            />
            <div class="label">
              <span class="label-text-alt">
                6-digit authenticator code or 8-character backup code
              </span>
            </div>
          </div>

          <div class="form-control mt-4">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="two_factor[trust_device]"
                value="true"
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Trust this device for 30 days</span>
            </label>
            <label class="label">
              <span class="label-text-alt opacity-70">
                You won't need to enter a code on this device
              </span>
            </label>
          </div>

          <div class="mt-6">
            <button type="submit" class="btn btn-primary w-full">
              Verify
            </button>
          </div>
        </.form>

        <div class="mt-6 border-t border-base-300 pt-4 text-center">
          <p class="mb-3 text-sm text-base-content/70">
            Lost your authenticator device? Use a backup code in the same field.
          </p>
          <.link href={Elektrine.Paths.login_path()} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> Back to login
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
