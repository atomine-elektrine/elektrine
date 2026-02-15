defmodule ElektrineWeb.UserAuth do
  @moduledoc """
  Handles user authentication in the web layer.
  """
  use ElektrineWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Accounts
  alias Elektrine.Constants
  alias Elektrine.Email.Cached, as: EmailCached
  alias Elektrine.AppCache

  # Make the remember me cookie valid for 60 days.
  # If you want to customize, set :elektrine, :user_remember_me_cookie_max_age
  @max_age Constants.session_max_age_seconds()
  @remember_me_cookie "_elektrine_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the OWASP guidelines
  for more information.

  It also sets a cookie with the user's ID.
  This is used to remember users when they return to the app.
  """
  def log_in_user(conn, user, params \\ %{}, opts \\ []) do
    token = Phoenix.Token.sign(conn, "user auth", user.id)
    user_return_to = get_session(conn, :user_return_to)

    # Update login information (IP, timestamp, count)
    remote_ip = get_remote_ip(conn)
    Accounts.update_user_login_info(user, remote_ip)

    # Warm up caches for the user after successful login
    warm_user_caches(user)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> store_session_ip_for_admin(user, remote_ip)
    |> maybe_write_remember_me_cookie(token, params)
    |> maybe_put_session_values(opts[:session])
    |> maybe_put_flash(opts[:flash])
    |> redirect(to: user_return_to || signed_in_path(conn, user))
  end

  defp maybe_put_flash(conn, nil), do: conn
  defp maybe_put_flash(conn, {type, message}), do: put_flash(conn, type, message)

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

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
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
      {:ok, user_id} -> Accounts.get_user!(user_id)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Confirms if the current user is authenticated.
  Used as a plug to ensure authentication in controllers.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %{banned: true} = user ->
        message =
          if user.banned_reason && String.trim(user.banned_reason) != "" do
            "Your account has been banned. Reason: #{user.banned_reason}"
          else
            "Your account has been banned. Please contact support if you believe this is an error."
          end

        conn
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
            if user.suspension_reason && String.trim(user.suspension_reason) != "" do
              "#{base_message}. Reason: #{user.suspension_reason}"
            else
              "#{base_message}. Please contact support if you believe this is an error."
            end

          conn
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
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/login")
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
          # SECURITY: Verify admin session IP hasn't changed (session hijacking detection)
          verify_admin_session_ip(conn, user)
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
    # Get user's mailbox
    case Elektrine.Email.get_user_mailbox(user.id) do
      nil ->
        :ok

      mailbox ->
        # Warm both email and app caches
        EmailCached.warm_user_cache(user.id, mailbox.id)
        AppCache.warm_user_cache(user.id, mailbox.id)
    end
  end

  # Helper function to get remote IP address
  defp get_remote_ip(conn) do
    # Try to get real IP from proxy headers first (Cloudflare, nginx, etc.)
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) ->
        ip

      _ ->
        case get_req_header(conn, "x-forwarded-for") do
          [forwarded | _] when is_binary(forwarded) ->
            # X-Forwarded-For can have multiple IPs, get the first (original client)
            forwarded
            |> String.split(",")
            |> List.first()
            |> String.trim()

          _ ->
            case get_req_header(conn, "x-real-ip") do
              [ip | _] when is_binary(ip) ->
                ip

              _ ->
                # Fallback to direct connection IP
                conn.remote_ip |> :inet.ntoa() |> to_string()
            end
        end
    end
  end

  # Store IP address in session for admin users (IP binding for session hijacking detection)
  defp store_session_ip_for_admin(conn, %{is_admin: true}, remote_ip) do
    put_session(conn, :admin_session_ip, remote_ip)
  end

  defp store_session_ip_for_admin(conn, _user, _remote_ip) do
    # Non-admin users don't need IP binding
    conn
  end

  # Verify admin session IP hasn't changed (session hijacking detection)
  defp verify_admin_session_ip(conn, user) do
    session_ip = get_session(conn, :admin_session_ip)
    current_ip = get_remote_ip(conn)

    cond do
      # No session IP stored - first request after login or old session, store current IP
      is_nil(session_ip) ->
        require Logger

        Logger.info(
          "Admin session IP binding: Initializing IP for user #{user.id} (#{user.username}) - IP: #{current_ip}"
        )

        put_session(conn, :admin_session_ip, current_ip)

      # IP matches - allow access
      session_ip == current_ip ->
        conn

      # IP changed - potential session hijacking detected
      true ->
        require Logger

        Logger.warning(
          "SECURITY ALERT: Admin session IP mismatch detected for user #{user.id} (#{user.username}). Session IP: #{session_ip}, Current IP: #{current_ip}. Logging out user."
        )

        conn
        |> put_flash(
          :error,
          "Your session was terminated due to suspicious activity. Please log in again."
        )
        |> log_out_user()
    end
  end
end
