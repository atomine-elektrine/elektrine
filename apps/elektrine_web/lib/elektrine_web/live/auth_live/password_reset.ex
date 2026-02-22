defmodule ElektrineWeb.AuthLive.PasswordReset do
  use ElektrineWeb, :live_view

  # Note: on_mount is handled by live_session :auth in router

  def mount(_params, session, socket) do
    via_tor = via_tor_request?(socket, session)

    {:ok,
     assign(socket,
       page_title: "Reset Password",
       via_tor: via_tor,
       turnstile_site_key: Application.get_env(:elektrine, :turnstile)[:site_key]
     )}
  end

  defp via_tor_request?(socket, session) do
    session["via_tor"] ||
      case socket.host_uri do
        %URI{host: host} when is_binary(host) -> String.ends_with?(host, ".onion")
        _ -> false
      end
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
                <%= if @via_tor do %>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">{gettext("Solve the problem")}</span>
                    </label>
                    <div class="flex items-center gap-3">
                      <img src={~p"/captcha"} alt="Captcha" class="rounded border border-base-300" />
                      <a href={~p"/password/reset"} class="btn btn-ghost btn-sm">
                        {gettext("Refresh")}
                      </a>
                    </div>
                    <input
                      type="text"
                      name="password_reset[captcha_answer]"
                      placeholder={gettext("Your answer")}
                      required
                      autocomplete="off"
                      class="input input-bordered w-full mt-2"
                    />
                  </div>
                <% else %>
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
                  <input
                    type="hidden"
                    name="cf-turnstile-response"
                    id="cf-turnstile-response"
                    value=""
                  />
                <% end %>
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
