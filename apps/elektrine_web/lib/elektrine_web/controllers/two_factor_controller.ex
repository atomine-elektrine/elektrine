defmodule ElektrineWeb.TwoFactorController do
  use ElektrineWeb, :controller
  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Accounts.TrustedDevice
  alias Elektrine.Auth.RateLimiter
  alias Elektrine.Telemetry.Events
  alias ElektrineWeb.UserAuth

  def new(conn, _params) do
    user = UserAuth.get_user_for_two_factor_verification(conn)

    if user do
      # Check if user is rate limited
      identifier = "2fa:#{user.id}"

      case RateLimiter.check_rate_limit(identifier) do
        {:ok, :allowed} ->
          render(conn, :new, error_message: nil)

        {:error, {:rate_limited, retry_after, _reason}} ->
          minutes = div(retry_after, 60)
          seconds = rem(retry_after, 60)

          time_msg =
            if minutes > 0 do
              "#{minutes} minute(s)"
            else
              "#{seconds} second(s)"
            end

          Logger.warning("2FA rate limit exceeded for user #{user.id} (#{user.username})")
          Events.auth(:two_factor, :rate_limited, %{reason: :rate_limit})

          conn
          |> put_flash(:error, "Too many failed attempts. Please try again in #{time_msg}.")
          |> render(:new, error_message: nil)
      end
    else
      Events.auth(:two_factor, :failure, %{reason: :session_expired})

      conn
      |> put_flash(:error, "Two-factor authentication session expired. Please log in again.")
      |> redirect(to: ~p"/login")
    end
  end

  def create(conn, %{"two_factor" => %{"code" => code} = params}) do
    user = UserAuth.get_user_for_two_factor_verification(conn)

    if user do
      # Rate limit identifier based on user ID
      identifier = "2fa:#{user.id}"

      # Check rate limit before attempting verification
      case RateLimiter.check_rate_limit(identifier) do
        {:ok, :allowed} ->
          # Proceed with 2FA verification
          case Accounts.verify_two_factor_code(user, code) do
            {:ok, :totp} ->
              # Clear rate limiting on successful verification
              RateLimiter.record_successful_attempt(identifier)
              Logger.info("Successful 2FA verification for user #{user.id} (#{user.username})")
              Events.auth(:two_factor, :success, %{reason: :totp})

              # Handle device trust if requested
              conn =
                if Map.get(params, "trust_device") == "true" do
                  create_trusted_device(conn, user)
                else
                  conn
                end

              flash_message = UserAuth.login_flash_message(user, method: :totp)
              UserAuth.complete_two_factor_login(conn, user, %{}, flash: {:info, flash_message})

            {:ok, :backup_code} ->
              # Clear rate limiting on successful verification
              RateLimiter.record_successful_attempt(identifier)
              remaining_count = length(user.two_factor_backup_codes || []) - 1
              Events.auth(:two_factor, :success, %{reason: :backup_code})

              Logger.info(
                "Successful 2FA verification (backup code) for user #{user.id} (#{user.username})"
              )

              # Handle device trust if requested
              conn =
                if Map.get(params, "trust_device") == "true" do
                  create_trusted_device(conn, user)
                else
                  conn
                end

              flash_message =
                UserAuth.login_flash_message(user,
                  method: :backup_code,
                  backup_codes_remaining: remaining_count
                )

              UserAuth.complete_two_factor_login(conn, user, %{}, flash: {:info, flash_message})

            {:error, :invalid_code} ->
              # Record failed attempt for rate limiting
              RateLimiter.record_failed_attempt(identifier)
              Events.auth(:two_factor, :failure, %{reason: :invalid_code})

              Logger.warning(
                "Failed 2FA verification attempt for user #{user.id} (#{user.username})"
              )

              conn
              |> put_flash(
                :error,
                "Invalid code. Common fixes: (1) Enable automatic date/time in your device settings, (2) Make sure you're entering the latest code from your authenticator app, (3) Try waiting for the next code. Contact support if issues persist."
              )
              |> render(:new, error_message: nil)

            {:error, _reason} ->
              # Record failed attempt for rate limiting
              RateLimiter.record_failed_attempt(identifier)
              Events.auth(:two_factor, :failure, %{reason: :verification_error})

              Logger.warning(
                "Failed 2FA verification attempt for user #{user.id} (#{user.username})"
              )

              conn
              |> put_flash(:error, "Authentication failed. Please try again.")
              |> render(:new, error_message: nil)
          end

        {:error, {:rate_limited, retry_after, _reason}} ->
          # User is rate limited
          minutes = div(retry_after, 60)
          seconds = rem(retry_after, 60)

          time_msg =
            if minutes > 0 do
              "#{minutes} minute(s)"
            else
              "#{seconds} second(s)"
            end

          Logger.warning("2FA rate limit exceeded for user #{user.id} (#{user.username})")
          Events.auth(:two_factor, :rate_limited, %{reason: :rate_limit})

          conn
          |> put_status(:too_many_requests)
          |> put_flash(:error, "Too many failed attempts. Please try again in #{time_msg}.")
          |> render(:new, error_message: nil)
      end
    else
      Events.auth(:two_factor, :failure, %{reason: :session_expired})

      conn
      |> put_flash(:error, "Two-factor authentication session expired. Please log in again.")
      |> redirect(to: ~p"/login")
    end
  end

  # Private helper to create a trusted device
  defp create_trusted_device(conn, user) do
    # Get device information
    user_agent = get_req_header(conn, "user-agent") |> List.first()
    ip_address = to_string(:inet_parse.ntoa(conn.remote_ip))

    # Generate device name from user agent
    device_name = parse_device_name(user_agent)

    # Create trusted device
    changeset =
      TrustedDevice.new_trusted_device(user.id, %{
        device_name: device_name,
        user_agent: user_agent,
        ip_address: ip_address
      })

    case Elektrine.Repo.insert(changeset) do
      {:ok, trusted_device} ->
        # Log device creation without exposing the full token
        token_preview = String.slice(trusted_device.device_token, 0, 8) <> "..."
        Logger.info("Created trusted device for user #{user.id}: #{token_preview}")

        # Set the device token in a cookie (valid for 30 days)
        conn
        |> put_resp_cookie("device_token", trusted_device.device_token,
          # 30 days
          max_age: 30 * 24 * 60 * 60,
          http_only: true,
          secure: true,
          same_site: "Lax"
        )

      {:error, _changeset} ->
        Logger.error("Failed to create trusted device for user #{user.id}")
        conn
    end
  end

  # Parse device name from user agent
  defp parse_device_name(nil), do: "Unknown Device"

  defp parse_device_name(user_agent) do
    cond do
      String.contains?(user_agent, "iPhone") -> "iPhone"
      String.contains?(user_agent, "iPad") -> "iPad"
      String.contains?(user_agent, "Android") -> "Android Device"
      String.contains?(user_agent, "Windows") -> "Windows PC"
      String.contains?(user_agent, "Macintosh") -> "Mac"
      String.contains?(user_agent, "Linux") -> "Linux PC"
      true -> "Unknown Device"
    end
  end
end
