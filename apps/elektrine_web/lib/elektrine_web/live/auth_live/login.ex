defmodule ElektrineWeb.AuthLive.Login do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.Passkeys

  # Note: on_mount is handled by live_session :auth in router

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Log in",
       passkey_loading: false
     )}
  end

  def render(assigns) do
    ~H"""
    <div id="login-card" phx-hook="GlassCard" class="card glass-card shadow-xl max-w-md mx-auto">
      <div class="card-body">
        <h1 class="text-center text-3xl font-bold mb-6">{gettext("Log in")}</h1>

        <.simple_form
          :let={f}
          for={%{}}
          action={~p"/login"}
          as={:user}
          method="post"
          bare={true}
          phx-hook="FormSubmit"
          id="login-form"
        >
          <.input
            field={f[:username]}
            type="text"
            label={gettext("Username")}
            placeholder={gettext("Enter your username")}
            required
          />
          <.input
            field={f[:password]}
            type="password"
            label={gettext("Password")}
            placeholder={gettext("Enter your password")}
            required
          />

          <:actions>
            <div class="flex flex-col gap-4 w-full">
              <div class="flex flex-col gap-2">
                <div>
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="checkbox"
                      name="user[remember_me]"
                      value="true"
                      class="checkbox checkbox-primary"
                    />
                    <span>{gettext("Keep me logged in")}</span>
                  </label>
                </div>
                <div class="text-center">
                  <.link href={~p"/password/reset"} class="link link-primary text-sm">
                    {gettext("Forgot your password?")}
                  </.link>
                </div>
              </div>

              <.button class="w-full">{gettext("Log in")}</.button>
            </div>
          </:actions>
        </.simple_form>

        <div class="divider mt-6">{gettext("OR")}</div>

        <button
          id="passkey-login"
          phx-hook="PasskeyAuth"
          class="btn btn-outline w-full"
          type="button"
          disabled={@passkey_loading}
        >
          <%= if @passkey_loading do %>
            <span class="loading loading-spinner loading-sm"></span>
          <% else %>
            <.icon name="hero-finger-print" class="w-5 h-5" />
          <% end %>
          {gettext("Sign in with passkey")}
        </button>

        <div class="divider">{gettext("OR")}</div>

        <div class="text-center">
          <.link href={~p"/register"} class="btn btn-ghost btn-sm">
            {gettext("Create an account")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Handle passkey authentication challenge request from the JS hook.
  """
  def handle_event("get_passkey_challenge", _params, socket) do
    socket = assign(socket, :passkey_loading, true)
    host = get_request_host(socket)

    {:ok, challenge_data} = Passkeys.generate_authentication_challenge(nil, host: host)

    {:noreply,
     socket
     |> push_event("passkey_auth_challenge", %{
       challenge_b64: challenge_data.challenge_b64,
       rp_id: challenge_data.rp_id,
       timeout: challenge_data.timeout,
       user_verification: challenge_data.user_verification,
       allow_credentials: challenge_data.allow_credentials
     })}
  end

  defp get_request_host(socket) do
    case socket.host_uri do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end
end
