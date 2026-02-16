defmodule ElektrineWeb.PasswordResetController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Turnstile
  alias Elektrine.Auth.RateLimiter
  alias Elektrine.Telemetry.Events

  def new(conn, _params) do
    render(conn, :new, error_message: nil)
  end

  def create(conn, %{
        "password_reset" => %{"username_or_email" => username_or_email},
        "cf-turnstile-response" => captcha_token
      }) do
    # Get IP address for rate limiting and verification
    ip_address = get_client_ip(conn)

    # Verify Turnstile captcha first
    case Turnstile.verify(captcha_token, ip_address) do
      {:ok, :verified} ->
        # Check rate limit (5 attempts per minute, 10 per hour per IP)
        rate_limit_key = "password_reset:#{ip_address}"

        case RateLimiter.check_rate_limit(rate_limit_key) do
          {:ok, :allowed} ->
            RateLimiter.record_failed_attempt(rate_limit_key)

            case Accounts.initiate_password_reset(username_or_email) do
              {:ok, :user_not_found} ->
                # Still show success message to avoid username enumeration
                Events.auth(:password_reset_request, :accepted, %{reason: :user_not_found})

                conn
                |> put_flash(
                  :info,
                  "If an account with that username or recovery email exists, you will receive password reset instructions."
                )
                |> redirect(to: ~p"/login")

              {:ok, :emails_sent} ->
                # Successfully sent reset emails (possibly to multiple users)
                Events.auth(:password_reset_request, :accepted, %{reason: :emails_sent})

                conn
                |> put_flash(
                  :info,
                  "If an account with that username or recovery email exists, you will receive password reset instructions."
                )
                |> redirect(to: ~p"/login")

              {:ok, _user} ->
                Events.auth(:password_reset_request, :accepted, %{reason: :single_user})

                conn
                |> put_flash(
                  :info,
                  "If an account with that username or recovery email exists, you will receive password reset instructions."
                )
                |> redirect(to: ~p"/login")

              {:error, :no_recovery_email} ->
                Events.auth(:password_reset_request, :accepted, %{reason: :no_recovery_email})

                conn
                |> put_flash(
                  :info,
                  "If an account with that username or recovery email exists, you will receive password reset instructions."
                )
                |> redirect(to: ~p"/login")

              {:error, _changeset} ->
                Events.auth(:password_reset_request, :failure, %{reason: :changeset_error})

                conn
                |> put_flash(
                  :error,
                  "There was an error processing your request. Please try again."
                )
                |> render(:new, error_message: nil)
            end

          {:error, {:rate_limited, retry_after, _reason}} ->
            Events.auth(:password_reset_request, :rate_limited, %{reason: :rate_limit})

            conn
            |> put_flash(
              :error,
              "Too many password reset requests. Please try again in #{format_retry_time(retry_after)}."
            )
            |> render(:new, error_message: nil)
        end

      {:error, :verification_failed} ->
        Events.auth(:password_reset_request, :failure, %{reason: :captcha_failed})

        conn
        |> put_flash(:error, "Captcha verification failed. Please try again.")
        |> render(:new, error_message: nil)

      {:error, {:verification_failed, _error_codes}} ->
        Events.auth(:password_reset_request, :failure, %{reason: :captcha_failed})

        conn
        |> put_flash(:error, "Captcha verification failed. Please try again.")
        |> render(:new, error_message: nil)

      {:error, _other} ->
        Events.auth(:password_reset_request, :failure, %{reason: :captcha_error})

        conn
        |> put_flash(:error, "Captcha verification failed. Please try again.")
        |> render(:new, error_message: nil)
    end
  end

  # Handle missing captcha token
  def create(conn, %{"password_reset" => _params}) do
    Events.auth(:password_reset_request, :failure, %{reason: :missing_captcha})

    conn
    |> put_flash(:error, "Please complete the captcha verification.")
    |> render(:new, error_message: nil)
  end

  def create(conn, %{"password_reset[username_or_email]" => username_or_email} = params) do
    # Handle flattened form parameters (when content-type is application/json)
    password_reset_params = %{"username_or_email" => username_or_email}

    new_params =
      Map.put(params, "password_reset", password_reset_params)
      |> Map.delete("password_reset[username_or_email]")

    create(conn, new_params)
  end

  def edit(conn, %{"token" => token}) do
    case Accounts.validate_password_reset_token(token) do
      {:ok, user} ->
        changeset = User.password_reset_with_token_changeset(user, %{})
        render(conn, :edit, token: token, changeset: changeset)

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Invalid or expired password reset link.")
        |> redirect(to: ~p"/password/reset")
    end
  end

  def update(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.reset_password_with_token(token, user_params) do
      {:ok, _user} ->
        Events.auth(:password_reset_confirm, :success, %{reason: :token_valid})

        conn
        |> put_flash(:info, "Password reset successfully. Please log in with your new password.")
        |> redirect(to: ~p"/login")

      {:error, :invalid_token} ->
        Events.auth(:password_reset_confirm, :failure, %{reason: :invalid_token})

        conn
        |> put_flash(:error, "Invalid or expired password reset link.")
        |> redirect(to: ~p"/password/reset")

      {:error, changeset} ->
        Events.auth(:password_reset_confirm, :failure, %{reason: :validation_error})
        render(conn, :edit, token: token, changeset: changeset)
    end
  end

  # Helper function to get client IP address
  # For IPv6, normalizes to /64 subnet to prevent address rotation attacks
  defp get_client_ip(conn) do
    ip_string = ElektrineWeb.ClientIP.client_ip(conn)

    normalize_ipv6_subnet(ip_string)
  end

  defp normalize_ipv6_subnet(ip_string) do
    if String.contains?(ip_string, ":") do
      hextets = String.split(ip_string, ":")

      if Enum.any?(hextets, &(&1 == "")) do
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after
        Enum.take(expanded, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      else
        Enum.take(hextets, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      end
    else
      ip_string
    end
  end

  defp format_retry_time(seconds) when seconds < 60, do: "#{seconds} seconds"

  defp format_retry_time(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    "#{minutes} minute#{if minutes == 1, do: "", else: "s"}"
  end

  defp format_retry_time(seconds) do
    hours = div(seconds, 3600)
    "#{hours} hour#{if hours == 1, do: "", else: "s"}"
  end
end
