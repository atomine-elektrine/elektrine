defmodule ElektrineWeb.AuthLive.Register do
  use ElektrineWeb, :live_view

  # Note: on_mount is handled by live_session :auth in router

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User

  def mount(_params, session, socket) do
    changeset = Accounts.change_user_registration(%User{})
    invite_codes_enabled = Elektrine.System.invite_codes_enabled?()
    via_tor = via_tor_request?(socket, session)
    turnstile_config = Application.get_env(:elektrine, :turnstile)
    site_key = turnstile_config[:site_key]

    require Logger
    Logger.info("Register mount: via_tor=#{via_tor}, turnstile_site_key=#{inspect(site_key)}")

    {:ok,
     assign(socket,
       page_title: "Register",
       changeset: changeset,
       invite_codes_enabled: invite_codes_enabled,
       via_tor: via_tor,
       turnstile_site_key: site_key
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
    <div id="register-card" phx-hook="GlassCard" class="card glass-card shadow-xl max-w-md mx-auto">
      <div class="card-body">
        <h1 class="text-center text-3xl font-bold mb-6">{gettext("Register")}</h1>

        <.simple_form
          :let={f}
          for={@changeset}
          action={~p"/register"}
          method="post"
          bare={true}
          phx-hook="FormSubmit"
          id="register-form"
        >
          <.error :if={@changeset.action}>
            {gettext("Oops, something went wrong! Please check the errors below.")}
          </.error>

          <.input
            field={f[:username]}
            type="text"
            label={gettext("Username")}
            placeholder={gettext("Enter your username")}
            required
          />
          <div>
            <.input
              field={f[:password]}
              type="password"
              label={gettext("Password")}
              placeholder={gettext("Enter your password")}
              required
            />
            <div class="label">
              <span class="text-xs opacity-70">
                {gettext("Password must be at least 12 characters long")}
              </span>
            </div>
          </div>
          <.input
            field={f[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            placeholder={gettext("Confirm your password")}
            required
          />

          <%= if @invite_codes_enabled do %>
            <.input
              field={f[:invite_code]}
              type="text"
              label={gettext("Invite Code")}
              placeholder={gettext("Enter your invite code")}
              required
            />
          <% end %>

          <div class="form-control my-4">
            <label class="label cursor-pointer justify-start gap-3 py-2">
              <input
                type="checkbox"
                name="user[agree_to_terms]"
                value="true"
                required
                class="checkbox checkbox-primary flex-shrink-0"
              />
              <span class="label-text text-sm leading-snug">
                {gettext("I agree to the")}
                <.link href={~p"/terms"} target="_blank" class="link link-primary">
                  {gettext("Terms")}
                </.link>
                &
                <.link href={~p"/privacy"} target="_blank" class="link link-primary">
                  {gettext("Privacy Policy")}
                </.link>
              </span>
            </label>
            <%= if tos_errors = @changeset.errors[:agree_to_terms] do %>
              <div class="label pt-0">
                <span class="label-text-alt text-error text-xs">
                  {case tos_errors do
                    {msg, _opts} -> msg
                    [{msg, _opts} | _] -> msg
                    _ -> gettext("You must agree to the Terms of Service")
                  end}
                </span>
              </div>
            <% end %>
          </div>

          <%= if @via_tor do %>
            <div class="w-full">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">{gettext("Solve the problem")}</span>
                </label>
                <div class="flex items-center gap-3">
                  <img src={~p"/captcha"} alt="Captcha" class="rounded border border-base-300" />
                  <a href={~p"/register"} class="btn btn-ghost btn-sm">{gettext("Refresh")}</a>
                </div>
                <input
                  type="text"
                  name="captcha_answer"
                  placeholder={gettext("Your answer")}
                  required
                  autocomplete="off"
                  class="input input-bordered w-full mt-2"
                />
              </div>
              <%= if captcha_errors = @changeset.errors[:captcha] do %>
                <div class="text-center mt-2">
                  <span class="text-error text-sm">
                    {case captcha_errors do
                      {msg, _opts} -> msg
                      [{msg, _opts} | _] -> msg
                      _ -> gettext("Please solve the captcha")
                    end}
                  </span>
                </div>
              <% end %>
            </div>
          <% else %>
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
              <input type="hidden" name="cf-turnstile-response" id="cf-turnstile-response" value="" />
              <%= if captcha_errors = @changeset.errors[:captcha] do %>
                <div class="text-center">
                  <span class="text-error text-sm">
                    {case captcha_errors do
                      {msg, _opts} -> msg
                      [{msg, _opts} | _] -> msg
                      _ -> gettext("Please complete the captcha verification")
                    end}
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>

          <:actions>
            <.button class="w-full">{gettext("Create account")}</.button>
          </:actions>
        </.simple_form>

        <div class="divider mt-6">{gettext("OR")}</div>

        <div class="text-center">
          <.link href={~p"/login"} class="btn btn-ghost btn-sm">
            {gettext("Already have an account? Log in")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
