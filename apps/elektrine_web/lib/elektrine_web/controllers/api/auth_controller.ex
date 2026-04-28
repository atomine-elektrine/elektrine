defmodule ElektrineWeb.API.AuthController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.EmailAddresses
  alias Elektrine.OAuth
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Endpoint
  alias ElektrineWeb.Plugs.APIAuth
  alias ElektrineWeb.UserAuth

  action_fallback ElektrineWeb.FallbackController

  @doc """
  POST /api/auth/login
  Authenticates a user and returns a token
  """
  def login(conn, %{"username" => username, "password" => password} = params) do
    identifiers = login_rate_limit_identifiers(conn, username)

    case check_login_rate_limits(identifiers) do
      :ok ->
        attempt_login(conn, username, password, Map.get(params, "two_factor_code"), identifiers)

      {:error, retry_after, reason} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", to_string(retry_after))
        |> json(%{
          error: "Too many login attempts",
          reason: reason,
          retry_after: retry_after
        })
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Username and password are required"})
  end

  defp attempt_login(conn, username, password, two_factor_code, identifiers) do
    case Accounts.Authentication.authenticate_user(username, password) do
      {:ok, user} ->
        if UserAuth.admin_login_restricted?(conn, user) do
          record_login_rate_limit_attempts(identifiers)

          conn
          |> put_status(:not_found)
          |> json(%{error: "Not Found"})
        else
          case verify_api_second_factor(user, two_factor_code) do
            :ok ->
              clear_login_rate_limits(identifiers)
              {:ok, token} = APIAuth.generate_token(user.id)

              conn
              |> put_status(:ok)
              |> json(%{
                token: token,
                user: %{
                  id: user.id,
                  username: user.username,
                  email: EmailAddresses.primary_for_user(user),
                  avatar: user.avatar,
                  is_admin: user.is_admin,
                  inserted_at: user.inserted_at,
                  updated_at: user.updated_at
                }
              })

            {:error, :two_factor_required} ->
              record_login_rate_limit_attempts(identifiers)

              conn
              |> put_status(:unauthorized)
              |> json(%{error: "Two-factor code required", reason: "two_factor_required"})

            {:error, :invalid_two_factor_code} ->
              record_login_rate_limit_attempts(identifiers)

              conn
              |> put_status(:unauthorized)
              |> json(%{error: "Invalid two-factor code", reason: "invalid_two_factor_code"})
          end
        end

      {:error, :invalid_credentials} ->
        # Record failed attempt for rate limiting
        record_login_rate_limit_attempts(identifiers)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid username or password"})

      {:error, {:banned, reason}} ->
        # Record failed attempt for rate limiting
        record_login_rate_limit_attempts(identifiers)

        conn
        |> put_status(:forbidden)
        |> json(%{error: "Account is banned", reason: reason})

      {:error, {:suspended, until, reason}} ->
        # Record failed attempt for rate limiting
        record_login_rate_limit_attempts(identifiers)

        conn
        |> put_status(:forbidden)
        |> json(%{error: "Account is suspended", until: until, reason: reason})

      {:error, _reason} ->
        # Record failed attempt for rate limiting
        record_login_rate_limit_attempts(identifiers)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication failed"})
    end
  end

  defp login_rate_limit_identifiers(conn, username) do
    ip = ClientIP.rate_limit_ip(conn)
    normalized_username = String.downcase(to_string(username || ""))
    ["#{ip}:#{normalized_username}", "ip:#{ip}", "user:#{normalized_username}"]
  end

  defp check_login_rate_limits(identifiers) do
    identifiers
    |> Enum.find_value(:ok, fn identifier ->
      case Elektrine.Auth.RateLimiter.check_rate_limit(identifier) do
        {:ok, :allowed} -> nil
        {:error, {:rate_limited, retry_after, reason}} -> {:error, retry_after, reason}
      end
    end)
  end

  defp record_login_rate_limit_attempts(identifiers) do
    Enum.each(identifiers, &Elektrine.Auth.RateLimiter.record_attempt/1)
  end

  defp clear_login_rate_limits(identifiers) do
    Enum.each(identifiers, &Elektrine.Auth.RateLimiter.clear_limits/1)
  end

  defp verify_api_second_factor(%{two_factor_enabled: true} = user, code) when is_binary(code) do
    case Accounts.verify_two_factor_code(user, String.trim(code)) do
      {:ok, _method} -> :ok
      _ -> {:error, :invalid_two_factor_code}
    end
  end

  defp verify_api_second_factor(%{two_factor_enabled: true}, _code),
    do: {:error, :two_factor_required}

  defp verify_api_second_factor(_user, _code), do: :ok

  @doc """
  POST /api/auth/logout
  Logs out the current user and revokes the current API token.
  """
  def logout(conn, _params) do
    case extract_bearer_token(conn) do
      {:ok, token} ->
        case APIAuth.revoke_token(token) do
          :ok ->
            Accounts.invalidate_auth_sessions(conn.assigns.current_user)
            OAuth.delete_user_tokens(conn.assigns.current_user)
            Endpoint.broadcast("user_socket:#{conn.assigns.current_user.id}", "disconnect", %{})

            conn
            |> put_status(:ok)
            |> json(%{message: "Logged out successfully"})

          {:error, _reason} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid token"})
        end

      {:error, :missing_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing token"})
    end
  end

  @doc """
  GET /api/auth/me
  Returns the current authenticated user
  """
  def me(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_status(:ok)
    |> json(%{
      user: %{
        id: user.id,
        username: user.username,
        email: EmailAddresses.primary_for_user(user),
        avatar: user.avatar,
        is_admin: user.is_admin,
        inserted_at: user.inserted_at,
        updated_at: user.updated_at
      }
    })
  end

  defp extract_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end
end
