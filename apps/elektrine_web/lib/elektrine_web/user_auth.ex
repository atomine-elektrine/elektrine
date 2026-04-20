defmodule ElektrineWeb.UserAuth do
  @moduledoc """
  Handles user authentication in the web layer.
  """
  use ElektrineWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Accounts
  alias Elektrine.Constants
  alias ElektrineWeb.AdminSecurity
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Endpoint
  alias ElektrineWeb.Platform.Integrations
  alias ElektrineWeb.SessionConfig

  # Make the remember me cookie valid for 60 days.
  # If you want to customize, set :elektrine, :user_remember_me_cookie_max_age
  @max_age Constants.session_max_age_seconds()
  @remember_me_cookie "_elektrine_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax", http_only: true]
  @recent_auth_session_key :user_recent_auth_at

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the OWASP guidelines
  for more information.

  It also sets a cookie with the user's ID.
  This is used to remember users when they return to the app.
  """
  def log_in_user(conn, user, params \\ %{}, opts \\ []) do
    token = Phoenix.Token.sign(conn, "user auth", user_session_claims(user))
    user_return_to = get_session(conn, :user_return_to)

    # Update login information (IP, timestamp, count)
    remote_ip = get_remote_ip(conn)
    Accounts.update_user_login_info(user, remote_ip)

    # Warm up caches for the user after successful login
    warm_user_caches(user)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> mark_recent_auth()
    |> maybe_write_remember_me_cookie(token, user, params)
    |> maybe_put_session_values(opts[:session])
    |> maybe_initialize_admin_security_session(user, opts)
    |> maybe_put_flash(opts[:flash])
    |> redirect(to: user_return_to || signed_in_path(conn, user))
  end

  defp maybe_put_flash(conn, nil), do: conn

  defp maybe_put_flash(conn, {type, message}),
    do: conn |> ensure_flash_fetched() |> put_flash(type, message)

  @doc """
  Generates a login success flash message based on user state and auth method.

  ## Options
    - `:method` - The auth method used: `:password`, `:passkey`, `:totp`, `:backup_code`, `:trusted_device`
    - `:backup_codes_remaining` - Number of backup codes remaining (for `:backup_code` method)
  """
  def login_flash_message(user, opts \\ []) do
    method = Keyword.get(opts, :method, :password)
    is_new = !user.onboarding_completed

    base =
      case {is_new, method} do
        {true, _} -> "Welcome!"
        {false, :passkey} -> "Logged in with passkey."
        {false, :totp} -> "Logged in with 2FA."
        {false, :backup_code} -> "Logged in with backup code."
        {false, _} -> "Logged in successfully."
      end

    # Append backup code warning if applicable
    case Keyword.get(opts, :backup_codes_remaining) do
      nil -> base
      count -> "#{base} You have #{count} backup codes remaining."
    end
  end

  defp maybe_put_session_values(conn, nil), do: conn

  defp maybe_put_session_values(conn, session_map) when is_map(session_map) do
    Enum.reduce(session_map, conn, fn {key, value}, acc ->
      put_session(acc, key, value)
    end)
  end

  defp maybe_initialize_admin_security_session(conn, user, opts) do
    admin_opts = [
      auth_method: opts[:auth_method] || opts[:method],
      passkey_credential_id: opts[:passkey_credential_id]
    ]

    AdminSecurity.initialize_admin_session(conn, user, admin_opts)
  end

  @doc """
  Stores a user's ID in session for 2FA verification.
  This is a temporary session used during the 2FA verification process.
  """
  def store_user_for_two_factor_verification(conn, user) do
    conn
    |> renew_session()
    |> put_session(:two_factor_user_id, user.id)
    |> put_session(:two_factor_timestamp, System.system_time(:second))
  end

  @doc """
  Retrieves the user stored for 2FA verification.
  Returns nil if no user is stored or if the session has expired (15 minutes).
  """
  def get_user_for_two_factor_verification(conn) do
    user_id = get_session(conn, :two_factor_user_id)
    timestamp = get_session(conn, :two_factor_timestamp)

    current_time = System.system_time(:second)
    fifteen_minutes = 15 * 60

    if user_id && timestamp && current_time - timestamp < fifteen_minutes do
      try do
        Accounts.get_user!(user_id)
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Clears the 2FA verification session.
  """
  def clear_two_factor_session(conn) do
    conn
    |> delete_session(:two_factor_user_id)
    |> delete_session(:two_factor_timestamp)
  end

  @doc """
  Completes the 2FA login process by logging in the user.
  """
  def complete_two_factor_login(conn, user, params \\ %{}, opts \\ []) do
    # Also warm caches for 2FA completion
    warm_user_caches(user)

    conn
    |> clear_two_factor_session()
    |> log_in_user(user, params, opts)
  end

  defp maybe_write_remember_me_cookie(conn, _token, %{is_admin: true}, %{"remember_me" => "true"}) do
    # Admin sessions are intentionally short-lived and cannot be remembered.
    conn
  end

  defp maybe_write_remember_me_cookie(conn, token, _user, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, remember_me_options(conn))
  end

  defp maybe_write_remember_me_cookie(conn, _token, _user, _params) do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks.
  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    put_session(conn, :user_token, token)
  end

  def mark_recent_auth(conn) do
    put_session(conn, @recent_auth_session_key, System.system_time(:second))
  end

  def recent_auth_session_key, do: @recent_auth_session_key

  def recent_auth_ttl_seconds do
    Application.get_env(:elektrine, :user_security, [])
    |> Keyword.get(:recent_auth_ttl_seconds, 15 * 60)
  end

  def recent_auth_valid?(recent_auth_at) when is_integer(recent_auth_at) do
    recent_auth_at + recent_auth_ttl_seconds() >= System.system_time(:second)
  end

  def recent_auth_valid?(_), do: false

  defp signed_in_path(_conn, user) do
    # Redirect to onboarding if not completed
    # Handle both false and nil (for legacy users)
    if user.onboarding_completed == true do
      ~p"/"
    else
      ~p"/onboarding"
    end
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See the OWASP guidelines
  for more information on this.
  """
  def log_out_user(conn) do
    maybe_invalidate_current_user_sessions(conn.assigns[:current_user])

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && fetch_user_by_token(user_token)
    assign(conn, :current_user, user)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  defp fetch_user_by_token(token) do
    case Phoenix.Token.verify(ElektrineWeb.Endpoint, "user auth", token, max_age: @max_age) do
      {:ok, claims} -> claims |> session_user_id() |> fetch_user_for_claims(claims)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp user_session_claims(user) do
    %{
      "user_id" => user.id,
      "password_changed_at" => password_changed_at_unix(user),
      "auth_valid_after" => auth_valid_after_unix(user)
    }
  end

  defp fetch_user_for_claims(nil, _claims), do: nil

  defp fetch_user_for_claims(user_id, claims) do
    user = Accounts.get_user!(user_id)

    if session_claims_valid?(user, claims) do
      user
    else
      nil
    end
  end

  defp session_user_id(%{"user_id" => user_id}) when is_integer(user_id), do: user_id
  defp session_user_id(_claims), do: nil

  defp session_claims_valid?(user, %{
         "password_changed_at" => changed_at,
         "auth_valid_after" => valid_after
       }) do
    password_changed_at_unix(user) == changed_at and auth_valid_after_unix(user) == valid_after
  end

  defp session_claims_valid?(_user, _claims), do: false

  defp password_changed_at_unix(%{last_password_change: %DateTime{} = changed_at}) do
    DateTime.to_unix(changed_at)
  end

  defp password_changed_at_unix(_user), do: nil

  defp auth_valid_after_unix(%{auth_valid_after: %DateTime{} = valid_after}) do
    DateTime.to_unix(valid_after)
  end

  defp auth_valid_after_unix(_user), do: nil

  defp maybe_invalidate_current_user_sessions(%{} = user) do
    case Accounts.invalidate_auth_sessions(user) do
      {:ok, _user} -> Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
      _ -> :ok
    end
  end

  defp maybe_invalidate_current_user_sessions(_), do: :ok

  @doc """
  Confirms if the current user is authenticated.
  Used as a plug to ensure authentication in controllers.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %{banned: true} = user ->
        message =
          if Elektrine.Strings.present?(user.banned_reason) do
            "Your account has been banned. Reason: #{user.banned_reason}"
          else
            "Your account has been banned. Please contact support if you believe this is an error."
          end

        conn
        |> ensure_flash_fetched()
        |> put_flash(:error, message)
        |> log_out_user()

      %{suspended: true} = user ->
        if Elektrine.Accounts.user_suspended?(user) do
          base_message =
            if user.suspended_until do
              "Your account is suspended until #{Calendar.strftime(user.suspended_until, "%B %d, %Y")}"
            else
              "Your account is suspended"
            end

          message =
            if Elektrine.Strings.present?(user.suspension_reason) do
              "#{base_message}. Reason: #{user.suspension_reason}"
            else
              "#{base_message}. Please contact support if you believe this is an error."
            end

          conn
          |> ensure_flash_fetched()
          |> put_flash(:error, message)
          |> log_out_user()
        else
          # Suspension has expired, auto-unsuspend
          {:ok, _} = Elektrine.Accounts.unsuspend_user(user)
          conn
        end

      %{} = _user ->
        conn

      nil ->
        conn
        |> ensure_flash_fetched()
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: Elektrine.Paths.login_path())
        |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  @doc """
  Redirects already authenticated users.
  Used as a plug in login/registration pages to prevent authenticated users
  from accessing these pages.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        conn
        |> redirect(to: signed_in_path(conn, user))
        |> halt()
    end
  end

  @doc """
  Ensures the current user is an admin.
  Used as a plug to restrict admin-only routes.
  Returns 404 for all non-admin users to hide the existence of admin routes.
  """
  def require_admin_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %{is_admin: true} ->
        conn

      _ ->
        # Return 404 to make admin routes appear non-existent
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
        |> Phoenix.Controller.render(:"404")
        |> halt()
    end
  end

  @doc """
  Special authentication for admin routes.
  Returns 404 for all unauthenticated or non-admin users to hide admin routes.
  Implements IP binding for admin sessions to detect potential session hijacking.
  """
  def require_admin_access(conn, _opts) do
    require Logger
    user = conn.assigns[:current_user]

    Logger.info(
      "require_admin_access: user=#{inspect(user && user.username)}, is_admin=#{inspect(user && user.is_admin)}"
    )

    case conn.assigns[:current_user] do
      %{is_admin: true, banned: false} = user ->
        # Check if suspended
        if user.suspended && Elektrine.Accounts.user_suspended?(user) do
          # Even suspended admins get 404 to hide admin routes
          conn
          |> put_status(:not_found)
          |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
          |> Phoenix.Controller.render(:"404")
          |> halt()
        else
          AdminSecurity.enforce_controller_security(conn, user)
        end

      %{banned: true} ->
        # Banned users get 404 to hide admin routes
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
        |> Phoenix.Controller.render(:"404")
        |> halt()

      _ ->
        # All other cases (not logged in, not admin) get 404
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.put_view(ElektrineWeb.ErrorHTML)
        |> Phoenix.Controller.render(:"404")
        |> halt()
    end
  end

  # Private cache warming function
  defp warm_user_caches(user) do
    Integrations.warm_user_auth_email_caches(user)
  end

  # Helper function to get remote IP address
  defp get_remote_ip(conn) do
    ClientIP.client_ip(conn)
  end

  defp remember_me_options(conn) do
    Keyword.put(@remember_me_options, :secure, SessionConfig.secure_cookies?(conn))
  end

  defp ensure_flash_fetched(%Plug.Conn{assigns: %{flash: _}} = conn), do: conn

  defp ensure_flash_fetched(conn) do
    fetch_flash(conn, [])
  end
end
