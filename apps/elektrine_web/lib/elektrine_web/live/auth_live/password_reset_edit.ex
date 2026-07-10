defmodule ElektrineWeb.AuthLive.PasswordResetEdit do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Vault

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
           valid_token: true,
           encrypted_data_configured: Vault.configured?(user.id)
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
    <.card id="password-reset-edit-card" class="max-w-md mx-auto">
      <:body>
        <%= if @valid_token do %>
          <h1 class="text-center text-3xl font-bold mb-6">Set New Password</h1>

          <p class="text-center opacity-70 mb-6">
            Enter your new password below.
          </p>

          <div
            :if={@encrypted_data_configured}
            class="mb-4 rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-base-content/80"
          >
            This resets your login password only. After logging in, use your encrypted data recovery code at
            <span class="font-mono">/account/encrypted-data</span>
            before unlocking Nerve, Kairo, or private mail.
          </div>

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
            <.button href={Elektrine.Paths.login_path()} variant="ghost" size="sm">
              Back to Login
            </.button>
          </div>
        <% else %>
          <h1 class="text-center text-3xl font-bold mb-6">Invalid Link</h1>
          <p class="text-center opacity-70 mb-6">
            This password reset link is invalid or has expired.
          </p>
          <div class="text-center">
            <.button href={~p"/password/reset"}>Request New Link</.button>
          </div>
        <% end %>
      </:body>
    </.card>
    """
  end
end
