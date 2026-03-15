defmodule ElektrineWeb.AuthLive.Register do
  use ElektrineWeb, :live_view

  # Note: on_mount is handled by live_session :auth in router

  import Ecto.Changeset, only: [add_error: 3, cast: 3]

  alias Elektrine.Subscriptions
  alias Elektrine.Subscriptions.Product
  alias Elektrine.Accounts.User

  def mount(params, session, socket) do
    changeset = registration_changeset(session, params)
    invite_codes_enabled = Elektrine.System.invite_codes_enabled?()
    via_tor = via_tor_request?(socket, session)

    registration_payment_product =
      if invite_codes_enabled, do: Subscriptions.get_active_registration_product(), else: nil

    turnstile_config = Application.get_env(:elektrine, :turnstile, [])
    site_key = turnstile_config[:site_key]

    turnstile_enabled =
      not Keyword.get(turnstile_config, :skip_verification, false) and is_binary(site_key) and
        String.trim(site_key) != ""

    require Logger

    Logger.info(
      "Register mount: via_tor=#{via_tor}, turnstile_enabled=#{turnstile_enabled}, turnstile_site_key=#{inspect(site_key)}"
    )

    socket =
      socket
      |> assign_new(:current_user, fn -> nil end)
      |> assign(
        page_title: "Register",
        changeset: changeset,
        invite_codes_enabled: invite_codes_enabled,
        via_tor: via_tor,
        registration_payment_product: registration_payment_product,
        registration_payment_price: format_registration_price(registration_payment_product),
        turnstile_site_key: site_key,
        turnstile_enabled: turnstile_enabled
      )

    {:ok, socket}
  end

  defp registration_changeset(session, params) do
    form_data = Map.get(session, "registration_form", %{})
    form_data = maybe_put_prefilled_invite_code(form_data, params)
    validation_errors = Map.get(session, "registration_errors", %{})

    changeset =
      %User{}
      |> cast(form_data, [
        :username,
        :password,
        :password_confirmation,
        :invite_code,
        :registration_ip,
        :registered_via_onion
      ])
      |> merge_session_errors(validation_errors)

    if changeset.errors == [] do
      changeset
    else
      %{changeset | action: :insert}
    end
  end

  defp merge_session_errors(%Ecto.Changeset{} = changeset, validation_errors) do
    Enum.reduce(validation_errors, changeset, fn {field, messages}, acc ->
      field = registration_field(field)

      Enum.reduce(List.wrap(messages), acc, fn message, current_changeset ->
        if Enum.any?(current_changeset.errors, fn
             {^field, {existing_message, _opts}} -> existing_message == message
             _other -> false
           end) do
          current_changeset
        else
          add_error(current_changeset, field, message)
        end
      end)
    end)
  end

  defp registration_field("username"), do: :username
  defp registration_field("password"), do: :password
  defp registration_field("password_confirmation"), do: :password_confirmation
  defp registration_field("invite_code"), do: :invite_code
  defp registration_field("agree_to_terms"), do: :agree_to_terms
  defp registration_field("captcha"), do: :captcha
  defp registration_field(field) when is_binary(field), do: String.to_existing_atom(field)

  defp via_tor_request?(socket, session) do
    session["via_tor"] ||
      case socket.host_uri do
        %URI{host: host} when is_binary(host) -> String.ends_with?(host, ".onion")
        _ -> false
      end
  end

  defp maybe_put_prefilled_invite_code(form_data, %{"invite_code" => invite_code})
       when is_binary(invite_code) do
    trimmed = String.trim(invite_code)

    if trimmed == "" or Map.get(form_data, "invite_code") do
      form_data
    else
      Map.put(form_data, "invite_code", trimmed)
    end
  end

  defp maybe_put_prefilled_invite_code(form_data, _params), do: form_data

  defp format_registration_price(%Product{} = product) do
    Product.format_price(product.one_time_price_cents, product.currency)
  end

  defp format_registration_price(_), do: nil

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
              <%= if @turnstile_enabled do %>
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
              <% end %>
            </div>
          <% end %>

          <:actions>
            <.button class="w-full">{gettext("Create account")}</.button>
          </:actions>
        </.simple_form>

        <%= if @invite_codes_enabled && @registration_payment_product do %>
          <div class="rounded-box border border-base-300 bg-base-200/50 p-4 mt-4">
            <div class="flex items-start justify-between gap-4">
              <div>
                <div class="font-medium">{gettext("Need an invite code?")}</div>
                <div class="text-sm opacity-70">
                  {gettext("Pay once to get a single-use invite for registration.")}
                </div>
              </div>
              <%= if @registration_payment_price do %>
                <div class="text-sm font-semibold whitespace-nowrap">
                  {@registration_payment_price}
                </div>
              <% end %>
            </div>

            <.form for={%{}} action={~p"/register/purchase"} method="post" class="mt-3">
              <button type="submit" class="btn btn-outline btn-sm w-full">
                {gettext("Buy Invite")}
              </button>
            </.form>
          </div>
        <% end %>

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
