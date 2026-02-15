defmodule ElektrineWeb.SettingsLive.EditPassword do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    changeset = Accounts.change_user_password(user)

    {:ok,
     assign(socket,
       page_title: "Change Password",
       changeset: changeset,
       user: user
     )}
  end

  def render(assigns) do
    ~H"""
    <div
      id="edit-password-card"
      phx-hook="GlassCard"
      class="card glass-card shadow-xl max-w-md mx-auto"
    >
      <div class="card-body">
        <h1 class="text-2xl font-bold mb-6">Change Password</h1>

        <.simple_form
          :let={f}
          for={@changeset}
          action={~p"/account/password"}
          method="put"
          bare={true}
        >
          <.error :if={@changeset.action}>
            Oops, something went wrong! Please check the errors below.
          </.error>

          <.input field={f[:current_password]} type="password" label="Current password" required />
          <.input field={f[:password]} type="password" label="New password" required />
          <.input
            field={f[:password_confirmation]}
            type="password"
            label="Confirm new password"
            required
          />

          <%= if @user.two_factor_enabled do %>
            <div class="form-control w-full">
              <label class="label">
                <span class="label-text">2FA Authentication Code</span>
              </label>
              <input
                type="text"
                name="user[two_factor_code]"
                placeholder="Enter your 6-digit code"
                class="input input-bordered w-full"
                required
                autocomplete="off"
                maxlength="6"
                pattern="[0-9]{6}"
              />
              <label class="label">
                <span class="label-text-alt">Required for password changes when 2FA is enabled</span>
              </label>
            </div>
          <% end %>

          <:actions>
            <.button>Change password</.button>
          </:actions>
        </.simple_form>

        <div class="divider"></div>

        <div class="mt-4">
          <.link href={~p"/account"} class="btn btn-ghost btn-sm">
            &larr; Back to account settings
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
