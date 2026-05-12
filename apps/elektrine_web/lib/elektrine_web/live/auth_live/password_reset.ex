defmodule ElektrineWeb.AuthLive.PasswordReset do
  use ElektrineWeb, :live_view

  alias ElektrineWeb.AtominePow

  def mount(_params, session, socket) do
    via_tor = via_tor_request?(socket, session)
    atomine_pow_enabled = AtominePow.enabled?()
    atomine_pow_difficulty = AtominePow.difficulty()

    {:ok,
     assign(socket,
       page_title: "Reset Password",
       via_tor: via_tor,
       atomine_pow_enabled: atomine_pow_enabled,
       atomine_pow_difficulty: atomine_pow_difficulty
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
      class="card panel-card max-w-md mx-auto"
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
                      <.link href={~p"/password/reset"} class="btn btn-ghost btn-sm">
                        {gettext("Refresh")}
                      </.link>
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
                  <%= if @atomine_pow_enabled do %>
                    <div class="rounded-box border border-base-300 bg-base-200/50 p-3">
                      <div
                        id="password-reset-atomine-pow"
                        phx-hook="AtominePow"
                        data-difficulty={@atomine_pow_difficulty}
                      >
                        <div class="flex items-start gap-3 text-left">
                          <div class="rounded-box bg-base-300/70 p-2 text-base-content/70">
                            <.icon name="hero-cpu-chip" class="h-4 w-4" />
                          </div>
                          <div class="min-w-0 flex-1">
                            <div class="flex flex-wrap items-center gap-2 text-sm">
                              <span class="font-semibold">Atomine Gate</span>
                              <span class="badge badge-outline badge-xs font-mono">
                                difficulty {@atomine_pow_difficulty}
                              </span>
                            </div>
                            <p class="text-xs text-base-content/70" data-atomine-pow-status>
                              two-layer gate: SHA-256 proof-of-work plus browser instrumentation, exchanged for an anonymous effort token.
                            </p>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <.button class="w-full">{gettext("Send Reset Link")}</.button>
            </div>
          </:actions>
        </.simple_form>

        <div class="divider mt-6">{gettext("OR")}</div>

        <div class="text-center">
          <.link href={Elektrine.Paths.login_path()} class="btn btn-ghost btn-sm">
            {gettext("Back to Login")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
