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
    <.card id="password-reset-card" class="max-w-md mx-auto">
      <:body>
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
                      <img
                        src={~p"/captcha"}
                        alt="Captcha"
                        class="rounded-lg border border-base-300"
                      />
                      <.button href={~p"/password/reset"} variant="ghost" size="sm">
                        {gettext("Refresh")}
                      </.button>
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
                    <div class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm">
                      <div
                        id="password-reset-atomine-pow"
                        phx-hook="AtominePow"
                        data-difficulty={@atomine_pow_difficulty}
                      >
                        <input type="hidden" name="atomine_pow_token" value="" />

                        <div class="space-y-2 text-left">
                          <div class="flex items-start justify-between gap-3">
                            <p class="font-semibold">Security check</p>
                            <span class="rounded-full bg-base-200 px-2 py-0.5 text-2xs text-base-content/70">
                              check level {@atomine_pow_difficulty}
                            </span>
                          </div>
                          <p class="text-xs leading-relaxed text-base-content/70">
                            Before sending the reset link, your browser does a short calculation. This slows automated requests without asking you to solve a puzzle.
                          </p>
                          <p class="text-xs text-base-content/60" data-atomine-pow-status>
                            This runs when you press Send Reset Link and usually takes a few seconds.
                          </p>
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
          <.button href={Elektrine.Paths.login_path()} variant="ghost" size="sm">
            {gettext("Back to Login")}
          </.button>
        </div>
      </:body>
    </.card>
    """
  end
end
