defmodule ElektrineWeb.AuthLive.PasswordReset do
  use ElektrineWeb, :live_view

  # Note: on_mount is handled by live_session :auth in router

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Reset Password",
       turnstile_site_key: Application.get_env(:elektrine, :turnstile)[:site_key]
     )}
  end

  def render(assigns) do
    ~H"""
    <div
      id="password-reset-card"
      phx-hook="GlassCard"
      class="card glass-card shadow-xl max-w-md mx-auto"
    >
      <div class="card-body">
        <h1 class="text-center text-3xl font-bold mb-6">{gettext("Reset Password")}</h1>

        <p class="text-center opacity-70 mb-6">
          {gettext(
            "Enter your username or recovery email address and we'll send you a link to reset your password."
          )}
        </p>

        <.simple_form :let={f} for={%{}} action={~p"/password/reset"} as={:password_reset} bare={true}>
          <.input
            field={f[:username_or_email]}
            type="text"
            label={gettext("Username or Recovery Email")}
            placeholder={gettext("Enter your username or recovery email")}
            required
          />

          <:actions>
            <div class="flex flex-col gap-4 w-full">
              <div class="w-full">
                <div class="turnstile-wrapper">
                  <div
                    id="turnstile-container"
                    phx-hook="Turnstile"
                    class="cf-turnstile"
                    data-sitekey={@turnstile_site_key}
                    data-theme="dark"
                    data-size="normal"
                  >
                  </div>
                </div>
              </div>

              <.button class="w-full">{gettext("Send Reset Link")}</.button>
            </div>
          </:actions>
        </.simple_form>

        <div class="divider mt-6">{gettext("OR")}</div>

        <div class="text-center">
          <.link href={~p"/login"} class="btn btn-ghost btn-sm">{gettext("Back to Login")}</.link>
        </div>
      </div>
    </div>
    """
  end
end
