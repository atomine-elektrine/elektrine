defmodule ElektrineChatWeb.API.AuthController do
  use ElektrineChatWeb, :controller

  alias Elektrine.Accounts
  alias ElektrineChatWeb.ClientIP
  alias ElektrineChatWeb.Plugs.APIAuth

  action_fallback ElektrineChatWeb.FallbackController

  @doc """
  POST /api/auth/login
  Authenticates a user and returns a token
  """
  def login(conn, %{"username" => username, "password" => password}) do
    # Get identifier for rate limiting (use IP + username)
    remote_ip = get_remote_ip(conn)
    identifier = "#{remote_ip}:#{username}"

    # Check rate limit before attempting authentication
    case Elektrine.Auth.RateLimiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        attempt_login(conn, username, password, identifier)

      {:error, {:rate_limited, retry_after, reason}} ->
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

  defp attempt_login(conn, username, password, identifier) do
    case Accounts.Authentication.authenticate_user(username, password) do
      {:ok, user} ->
        # Clear rate limit on successful login
        Elektrine.Auth.RateLimiter.clear_limits(identifier)

        # Generate token
        {:ok, token} = APIAuth.generate_token(user.id)

        conn
        |> put_status(:ok)
        |> json(%{
          token: token,
          user: %{
            id: user.id,
            username: user.username,
            email: "#{user.username}@elektrine.com",
            avatar: user.avatar,
            is_admin: user.is_admin,
            inserted_at: user.inserted_at,
            updated_at: user.updated_at
          }
        })

      {:error, :invalid_credentials} ->
        # Record failed attempt for rate limiting
        Elektrine.Auth.RateLimiter.record_attempt(identifier)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid username or password"})

      {:error, {:banned, reason}} ->
        # Record failed attempt for rate limiting
        Elektrine.Auth.RateLimiter.record_attempt(identifier)

        conn
        |> put_status(:forbidden)
        |> json(%{error: "Account is banned", reason: reason})

      {:error, {:suspended, until, reason}} ->
        # Record failed attempt for rate limiting
        Elektrine.Auth.RateLimiter.record_attempt(identifier)

        conn
        |> put_status(:forbidden)
        |> json(%{error: "Account is suspended", until: until, reason: reason})

      {:error, _reason} ->
        # Record failed attempt for rate limiting
        Elektrine.Auth.RateLimiter.record_attempt(identifier)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication failed"})
    end
  end

  @doc """
  POST /api/auth/logout
  Logs out the current user and revokes the current API token.
  """
  def logout(conn, _params) do
    case extract_bearer_token(conn) do
      {:ok, token} ->
        case APIAuth.revoke_token(token) do
          :ok ->
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
        email: "#{user.username}@elektrine.com",
        avatar: user.avatar,
        is_admin: user.is_admin,
        inserted_at: user.inserted_at,
        updated_at: user.updated_at
      }
    })
  end

  # Get remote IP with proxy header support
  defp get_remote_ip(conn) do
    ClientIP.client_ip(conn)
  end

  defp extract_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end
end
