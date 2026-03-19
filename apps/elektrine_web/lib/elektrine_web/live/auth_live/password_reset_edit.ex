defmodule ElektrineWeb.AuthLive.PasswordResetEdit do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User

  # Note: on_mount is handled by live_session :auth in router

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.validate_password_reset_token(token) do
      {:ok, user} ->
        changeset = User.password_reset_with_token_changeset(user, %{})

        {:ok,
         assign(socket,
           page_title: "Set New Password",
           token: token,
           changeset: changeset,
           valid_token: true
         )}

      {:error, :invalid_token} ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid or expired password reset link.")
         |> assign(page_title: "Set New Password", valid_token: false, token: nil, changeset: nil)}
    end
  end

  def render(assigns) do
    ~H"""
    <div
      id="password-reset-edit-card"
      phx-hook="GlassCard"
      class="card glass-card shadow-xl max-w-md mx-auto"
    >
      <div class="card-body">
        <%= if @valid_token do %>
          <h1 class="text-center text-3xl font-bold mb-6">Set New Password</h1>

          <p class="text-center opacity-70 mb-6">
            Enter your new password below.
          </p>

          <.simple_form
            :let={f}
            for={@changeset}
            action={~p"/password/reset/#{@token}"}
            method="put"
            bare={true}
          >
            <.error :if={@changeset.action}>
              Oops, something went wrong! Please check the errors below.
            </.error>

            <.input
              field={f[:password]}
              type="password"
              label="New password"
              placeholder="Enter your new password"
              required
            />

            <.input
              field={f[:password_confirmation]}
              type="password"
              label="Confirm new password"
              placeholder="Confirm your new password"
              required
            />

            <:actions>
              <.button class="w-full">Reset Password</.button>
            </:actions>
          </.simple_form>

          <div class="divider mt-6">OR</div>

          <div class="text-center">
            <.link href={~p"/login"} class="btn btn-ghost btn-sm">Back to Login</.link>
          </div>
        <% else %>
          <h1 class="text-center text-3xl font-bold mb-6">Invalid Link</h1>
          <p class="text-center opacity-70 mb-6">
            This password reset link is invalid or has expired.
          </p>
          <div class="text-center">
            <.link href={~p"/password/reset"} class="btn btn-primary">Request New Link</.link>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
