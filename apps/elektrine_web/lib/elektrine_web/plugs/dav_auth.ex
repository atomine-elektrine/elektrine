defmodule ElektrineWeb.Plugs.DAVAuth do
  @moduledoc """
  HTTP Basic Auth plug for CalDAV/CardDAV clients.

  Authenticates using:
  1. App passwords (recommended for 2FA users)
  2. Regular passwords (for non-2FA users)

  DAV clients like:
  - iOS/macOS Calendar and Contacts
  - Thunderbird
  - DAVx5 (Android)

  All use HTTP Basic Auth for authentication.
  """

  import Plug.Conn
  require Logger

  alias Elektrine.Accounts.Authentication
  alias Elektrine.Telemetry.Events

  @realm "Elektrine CalDAV/CardDAV"

  def init(opts), do: opts

  def call(conn, _opts) do
    # Enforce HTTPS in production (Basic Auth sends credentials in plain text)
    if Application.get_env(:elektrine, :env) == :prod && conn.scheme != :https do
      Events.auth(:dav, :failure, %{reason: :https_required})

      conn
      |> send_resp(403, "HTTPS required for CalDAV/CardDAV")
      |> halt()
    else
      case get_req_header(conn, "authorization") do
        ["Basic " <> encoded] ->
          authenticate_basic(conn, encoded)

        _ ->
          request_auth(conn)
      end
    end
  end

  defp authenticate_basic(conn, encoded) do
    case Base.decode64(encoded) do
      {:ok, credentials} ->
        case String.split(credentials, ":", parts: 2) do
          [username, password] ->
            authenticate_user(conn, username, password)

          _ ->
            request_auth(conn)
        end

      :error ->
        request_auth(conn)
    end
  end

  defp authenticate_user(conn, username, password) do
    # Get client IP for logging
    ip = get_client_ip(conn)

    # Try app password first (works for users with 2FA)
    case Authentication.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        Logger.debug("DAV auth successful via app password: #{username} from #{ip}")
        Events.auth(:dav, :success, %{reason: :app_password})
        assign(conn, :current_user, user)

      {:error, :user_not_found} ->
        # User doesn't exist - perform dummy hash to prevent timing attacks
        Argon2.no_user_verify()
        Logger.warning("DAV auth failed - user not found: #{username} from #{ip}")
        Events.auth(:dav, :failure, %{reason: :user_not_found})
        request_auth(conn)

      {:error, {:invalid_token, user}} ->
        # User exists but app password is wrong - try regular password
        # Only allow regular password if 2FA is NOT enabled
        try_regular_password(conn, user, password, ip)
    end
  end

  defp try_regular_password(conn, user, password, ip) do
    if user.two_factor_enabled do
      # User has 2FA - must use app password
      Logger.warning(
        "DAV auth failed - 2FA enabled, app password required: #{user.username} from #{ip}"
      )

      Events.auth(:dav, :failure, %{reason: :app_password_required})

      request_auth_with_message(conn, "2FA enabled - please use an app password")
    else
      # No 2FA - try regular password
      case Authentication.verify_user_password(user, password) do
        {:ok, _user} ->
          Logger.debug("DAV auth successful via password: #{user.username} from #{ip}")
          Events.auth(:dav, :success, %{reason: :password})
          assign(conn, :current_user, user)

        {:error, {:banned, _reason}} ->
          Logger.warning("DAV auth failed - user banned: #{user.username} from #{ip}")
          Events.auth(:dav, :failure, %{reason: :banned})
          send_resp(conn, 403, "Account banned") |> halt()

        {:error, {:suspended, _until, _reason}} ->
          Logger.warning("DAV auth failed - user suspended: #{user.username} from #{ip}")
          Events.auth(:dav, :failure, %{reason: :suspended})
          send_resp(conn, 403, "Account suspended") |> halt()

        {:error, _} ->
          Logger.warning("DAV auth failed - invalid credentials: #{user.username} from #{ip}")
          Events.auth(:dav, :failure, %{reason: :invalid_credentials})
          request_auth(conn)
      end
    end
  end

  defp request_auth(conn) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> send_resp(401, "Authentication required")
    |> halt()
  end

  defp request_auth_with_message(conn, message) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> send_resp(401, message)
    |> halt()
  end

  defp get_client_ip(conn) do
    # Check for forwarded IP headers
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          ip when is_tuple(ip) -> :inet.ntoa(ip) |> to_string()
          _ -> "unknown"
        end
    end
  end
end
