defmodule ElektrineWeb.PasskeyController do
  @moduledoc """
  Controller for WebAuthn/Passkey authentication.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts.Passkeys
  alias Elektrine.Auth.RateLimiter
  alias Elektrine.Telemetry.Events

  require Logger

  # Generic error message to prevent information disclosure
  @auth_failed_message "Passkey authentication failed. Please try again or use a different login method."

  @doc """
  Authenticate a user with a passkey assertion.

  This endpoint receives the WebAuthn assertion from the browser and verifies it.
  On success, logs the user in and redirects to the home page.
  """
  def authenticate(conn, %{"assertion" => assertion_json, "challenge" => challenge_b64}) do
    ip_address = get_client_ip(conn)

    # Check rate limit before processing
    case RateLimiter.check_rate_limit(ip_address) do
      {:ok, :allowed} ->
        process_authentication(conn, assertion_json, challenge_b64, ip_address)

      {:error, {:rate_limited, retry_after, _reason}} ->
        Events.auth(:passkey, :rate_limited, %{reason: :rate_limit})

        conn
        |> put_flash(
          :error,
          "Too many authentication attempts. Please try again in #{format_retry_time(retry_after)}."
        )
        |> redirect(to: ~p"/login")
    end
  end

  def authenticate(conn, _params) do
    Events.auth(:passkey, :failure, %{reason: :invalid_request})

    conn
    |> put_flash(:error, "Invalid authentication request")
    |> redirect(to: ~p"/login")
  end

  defp process_authentication(conn, assertion_json, challenge_b64, ip_address) do
    # Parse the assertion JSON
    case Jason.decode(assertion_json) do
      {:ok, assertion} ->
        # Decode the challenge from base64
        case Base.url_decode64(challenge_b64, padding: false) do
          {:ok, challenge_bytes} ->
            # Retrieve the stored challenge from cache
            case Passkeys.get_challenge(challenge_bytes) do
              {:ok, challenge} when not is_nil(challenge) ->
                verify_and_login(conn, challenge, assertion, ip_address)

              {:ok, nil} ->
                # Challenge expired or not found
                RateLimiter.record_failed_attempt(ip_address)
                Events.auth(:passkey, :failure, %{reason: :challenge_expired})

                conn
                |> put_flash(:error, "Authentication session expired. Please try again.")
                |> redirect(to: ~p"/login")
            end

          :error ->
            RateLimiter.record_failed_attempt(ip_address)
            Events.auth(:passkey, :failure, %{reason: :invalid_challenge})

            conn
            |> put_flash(:error, @auth_failed_message)
            |> redirect(to: ~p"/login")
        end

      {:error, _} ->
        RateLimiter.record_failed_attempt(ip_address)
        Events.auth(:passkey, :failure, %{reason: :invalid_assertion})

        conn
        |> put_flash(:error, @auth_failed_message)
        |> redirect(to: ~p"/login")
    end
  end

  defp verify_and_login(conn, challenge, assertion, ip_address) do
    case Passkeys.verify_authentication(challenge, assertion) do
      {:ok, user} ->
        # Clear rate limits on successful authentication
        RateLimiter.record_successful_attempt(ip_address)
        Events.auth(:passkey, :success, %{reason: :verified})

        # Log the user in - passkey auth bypasses 2FA
        flash_message = ElektrineWeb.UserAuth.login_flash_message(user, method: :passkey)

        conn
        |> ElektrineWeb.UserAuth.log_in_user(user, %{}, flash: {:info, flash_message})

      {:error, :cloned_authenticator} ->
        # Cloned authenticator detected - block authentication
        RateLimiter.record_failed_attempt(ip_address)
        Events.auth(:passkey, :failure, %{reason: :cloned_authenticator})

        Logger.warning(
          "Passkey authentication blocked: cloned authenticator detected from IP #{ip_address}"
        )

        conn
        |> put_flash(
          :error,
          "Security alert: This passkey may have been compromised. Please re-register your passkey."
        )
        |> redirect(to: ~p"/login")

      {:error, reason} ->
        RateLimiter.record_failed_attempt(ip_address)
        Events.auth(:passkey, :failure, %{reason: reason})
        Logger.warning("Passkey authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, @auth_failed_message)
        |> redirect(to: ~p"/login")
    end
  end

  defp get_client_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp format_retry_time(seconds) when seconds < 60, do: "#{seconds} seconds"
  defp format_retry_time(seconds), do: "#{div(seconds, 60)} minutes"
end
