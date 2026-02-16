defmodule ElektrineWeb.Plugs.JMAPAuth do
  @moduledoc """
  HTTP Basic Auth plug for JMAP clients.

  Authenticates using:
  1. App passwords (recommended for 2FA users)
  2. Regular passwords (for non-2FA users)

  JMAP clients use HTTP Basic Auth for authentication, similar to CalDAV/CardDAV.
  """

  import Plug.Conn
  require Logger

  alias Elektrine.Accounts.Authentication
  alias ElektrineWeb.ClientIP

  @realm "Elektrine JMAP"

  def init(opts), do: opts

  def call(conn, _opts) do
    # Enforce HTTPS for Basic Auth unless explicitly allowed for local development/testing.
    if https_required?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{type: "forbidden", detail: "HTTPS required for JMAP"}))
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

  defp https_required?(conn) do
    not https_request?(conn) and not allow_insecure_auth?()
  end

  defp https_request?(conn) do
    conn.scheme == :https or forwarded_as_https?(conn)
  end

  defp forwarded_as_https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [value | _] ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.downcase() == "https"

      _ ->
        false
    end
  end

  defp allow_insecure_auth? do
    Application.get_env(:elektrine, :allow_insecure_dav_jmap_auth, false)
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
    ip = get_client_ip(conn)

    # Try app password first (works for users with 2FA)
    case Authentication.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        Logger.debug("JMAP auth successful via app password: #{username} from #{ip}")

        conn
        |> assign(:current_user, user)
        |> assign(:jmap_account_id, "u#{user.id}")

      {:error, :user_not_found} ->
        Argon2.no_user_verify()
        Logger.warning("JMAP auth failed - user not found: #{username} from #{ip}")
        request_auth(conn)

      {:error, {:invalid_token, user}} ->
        try_regular_password(conn, user, password, ip)
    end
  end

  defp try_regular_password(conn, user, password, ip) do
    if user.two_factor_enabled do
      Logger.warning(
        "JMAP auth failed - 2FA enabled, app password required: #{user.username} from #{ip}"
      )

      request_auth_with_message(conn, "2FA enabled - please use an app password")
    else
      case Authentication.verify_user_password(user, password) do
        {:ok, _user} ->
          Logger.debug("JMAP auth successful via password: #{user.username} from #{ip}")

          conn
          |> assign(:current_user, user)
          |> assign(:jmap_account_id, "u#{user.id}")

        {:error, {:banned, _reason}} ->
          Logger.warning("JMAP auth failed - user banned: #{user.username} from #{ip}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{type: "forbidden", detail: "Account banned"}))
          |> halt()

        {:error, {:suspended, _until, _reason}} ->
          Logger.warning("JMAP auth failed - user suspended: #{user.username} from #{ip}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{type: "forbidden", detail: "Account suspended"}))
          |> halt()

        {:error, _} ->
          Logger.warning("JMAP auth failed - invalid credentials: #{user.username} from #{ip}")
          request_auth(conn)
      end
    end
  end

  defp request_auth(conn) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{type: "unauthorized", detail: "Authentication required"}))
    |> halt()
  end

  defp request_auth_with_message(conn, message) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{type: "unauthorized", detail: message}))
    |> halt()
  end

  defp get_client_ip(conn) do
    ClientIP.client_ip(conn)
  end
end
