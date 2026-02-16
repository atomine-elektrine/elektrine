defmodule ElektrineWeb.UserSessionController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.TrustedDevice
  alias Elektrine.Auth.RateLimiter
  alias Elektrine.Telemetry.Events
  alias ElektrineWeb.UserAuth
  require Logger

  def new(conn, _params) do
    render_login(conn)
  end

  # Handle login with or without captcha token (captcha removed from sign-in)
  def create(conn, %{"user" => user_params}) do
    %{"username" => username, "password" => password} = user_params

    # Get IP address for rate limiting
    ip_address = get_client_ip(conn)

    # Check rate limits for both IP and username
    case check_rate_limits(ip_address, username) do
      {:ok, :allowed} ->
        authenticate_and_handle_result(conn, username, password, user_params, ip_address)

      {:error, {:rate_limited, retry_after, _reason}} ->
        Events.auth(:password_login, :rate_limited, %{reason: :rate_limit})

        conn
        |> put_flash(
          :error,
          "Too many login attempts. Please try again in #{format_retry_time(retry_after)}."
        )
        |> render_login()
    end
  end

  # Catch-all for invalid login attempts (bots, scanners, etc.)
  def create(conn, _invalid_params) do
    # Log the attempt for security monitoring
    ip_address = get_client_ip(conn)
    require Logger
    Logger.warning("Invalid login attempt from #{ip_address} with non-standard params")
    Events.auth(:password_login, :failure, %{reason: :invalid_request})

    conn
    |> put_flash(:error, "Invalid login request.")
    |> render_login()
  end

  defp render_login(conn, _assigns \\ []) do
    # Redirect back to the LiveView login page instead of rendering the old template
    redirect(conn, to: ~p"/login")
  end

  defp authenticate_and_handle_result(conn, username, password, user_params, ip_address) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        # Record successful login attempt (clears rate limiting)
        RateLimiter.record_successful_attempt(ip_address)
        RateLimiter.record_successful_attempt(username)

        if user.two_factor_enabled do
          # Check if this device is trusted
          if device_is_trusted?(conn, user.id) do
            # Device is trusted, skip 2FA
            require Logger
            Logger.info("Skipping 2FA for user #{user.id} - trusted device")
            Events.auth(:password_login, :success, %{reason: :trusted_device})

            flash_message = UserAuth.login_flash_message(user, method: :trusted_device)
            UserAuth.log_in_user(conn, user, user_params, flash: {:info, flash_message})
          else
            # Require 2FA
            Events.auth(:password_login, :challenge_required, %{reason: :two_factor_required})

            conn
            |> UserAuth.store_user_for_two_factor_verification(user)
            |> redirect(to: ~p"/two_factor")
          end
        else
          Events.auth(:password_login, :success, %{reason: :password})
          flash_message = UserAuth.login_flash_message(user, method: :password)
          UserAuth.log_in_user(conn, user, user_params, flash: {:info, flash_message})
        end

      {:error, {:banned, banned_reason}} ->
        # Record failed attempt for banned account
        RateLimiter.record_failed_attempt(ip_address)
        RateLimiter.record_failed_attempt(username)
        Events.auth(:password_login, :failure, %{reason: :banned})

        message =
          if banned_reason && String.trim(banned_reason || "") != "" do
            "Your account has been banned. Reason: #{banned_reason}"
          else
            "Your account has been banned. Please contact support if you believe this is an error."
          end

        conn
        |> put_flash(:error, message)
        |> render_login()

      {:error, {:suspended, suspended_until, suspension_reason}} ->
        # Record failed attempt for suspended account
        RateLimiter.record_failed_attempt(ip_address)
        RateLimiter.record_failed_attempt(username)
        Events.auth(:password_login, :failure, %{reason: :suspended})

        base_message =
          if suspended_until do
            "Your account is suspended until #{Calendar.strftime(suspended_until, "%B %d, %Y at %I:%M %p UTC")}"
          else
            "Your account is suspended"
          end

        message =
          if suspension_reason && String.trim(suspension_reason || "") != "" do
            "#{base_message}. Reason: #{suspension_reason}"
          else
            "#{base_message}. Please contact support if you believe this is an error."
          end

        conn
        |> put_flash(:error, message)
        |> render_login()

      {:error, :invalid_credentials} ->
        # Record failed attempt for invalid credentials
        RateLimiter.record_failed_attempt(ip_address)
        RateLimiter.record_failed_attempt(username)
        Events.auth(:password_login, :failure, %{reason: :invalid_credentials})

        conn
        |> put_flash(:error, "Invalid username or password")
        |> render_login()
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  # Helper function to check rate limits for both IP and username
  defp check_rate_limits(ip_address, username) do
    case RateLimiter.check_rate_limit(ip_address) do
      {:ok, :allowed} ->
        RateLimiter.check_rate_limit(username)

      error ->
        error
    end
  end

  # Helper function to get client IP address
  # For IPv6, normalizes to /64 subnet to prevent address rotation attacks
  defp get_client_ip(conn) do
    ip_string = ElektrineWeb.ClientIP.client_ip(conn)

    # Normalize IPv6 to /64 subnet to prevent rotation attacks
    normalize_ipv6_subnet(ip_string)
  end

  # Normalizes IPv6 addresses to /64 subnet (first 4 hextets)
  # This prevents brute-force attacks using IPv6 address rotation
  # Example: 2001:db8:1234:5678::1 -> 2001:db8:1234:5678::/64
  defp normalize_ipv6_subnet(ip_string) do
    if String.contains?(ip_string, ":") do
      # IPv6 address - normalize to /64 subnet
      hextets = String.split(ip_string, ":")

      # Handle compressed notation (::)
      if Enum.any?(hextets, &(&1 == "")) do
        # Expand :: to appropriate number of 0s
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after

        # Take first 4 hextets for /64 subnet
        expanded
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      else
        # Not compressed - just take first 4 hextets
        hextets
        |> Enum.take(4)
        |> Enum.join(":")
        |> Kernel.<>("::/64")
      end
    else
      # IPv4 address - return as-is
      ip_string
    end
  end

  # Helper function to format retry time in a user-friendly way
  defp format_retry_time(seconds) when seconds < 60 do
    "#{seconds} seconds"
  end

  defp format_retry_time(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    "#{minutes} minute#{if minutes == 1, do: "", else: "s"}"
  end

  defp format_retry_time(seconds) do
    hours = div(seconds, 3600)
    "#{hours} hour#{if hours == 1, do: "", else: "s"}"
  end

  # Check if the current device is trusted for this user
  defp device_is_trusted?(conn, user_id) do
    case conn.cookies["device_token"] do
      nil ->
        false

      device_token ->
        import Ecto.Query

        # Find trusted device
        trusted_device =
          from(td in TrustedDevice,
            where: td.device_token == ^device_token and td.user_id == ^user_id,
            limit: 1
          )
          |> Elektrine.Repo.one()

        case trusted_device do
          nil ->
            false

          device ->
            # Check if device is still valid (not expired)
            if TrustedDevice.valid?(device) do
              # Update last_used_at asynchronously
              Elektrine.Async.start(fn ->
                device
                |> Ecto.Changeset.change(%{
                  last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
                })
                |> Elektrine.Repo.update()
              end)

              true
            else
              # Device expired, delete it asynchronously
              Elektrine.Async.start(fn -> Elektrine.Repo.delete(device) end)
              false
            end
        end
    end
  end
end
