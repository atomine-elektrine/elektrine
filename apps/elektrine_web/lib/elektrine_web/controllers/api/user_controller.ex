defmodule ElektrineWeb.API.UserController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias ElektrineWeb.Plugs.APIAuth

  action_fallback ElektrineWeb.FallbackController

  @doc """
  POST /api/users/register
  Registers a new user
  """
  def register(conn, %{"user" => user_params}) do
    # Extract username, email (optional), and password
    username = Map.get(user_params, "username")
    password = Map.get(user_params, "password")

    # Get IP for rate limiting
    remote_ip = get_remote_ip(conn)

    if is_nil(username) or is_nil(password) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Username and password are required"})
    else
      # Check rate limit (use IP-based limiting for registration)
      case Elektrine.Auth.RateLimiter.check_rate_limit("register:#{remote_ip}") do
        {:ok, :allowed} ->
          attempt_registration(conn, username, password, remote_ip)

        {:error, {:rate_limited, retry_after, reason}} ->
          conn
          |> put_status(:too_many_requests)
          |> put_resp_header("retry-after", to_string(retry_after))
          |> json(%{
            error: "Too many registration attempts",
            reason: reason,
            retry_after: retry_after
          })
      end
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error:
        "Invalid request format. Expected: {\"user\": {\"username\": \"...\", \"password\": \"...\"}}"
    })
  end

  defp attempt_registration(conn, username, password, remote_ip) do
    # Create user with minimal params
    case Accounts.create_user(%{
           username: username,
           password: password,
           password_confirmation: password
         }) do
      {:ok, user} ->
        # Clear rate limit on successful registration
        Elektrine.Auth.RateLimiter.clear_limits("register:#{remote_ip}")

        # Generate token
        {:ok, token} = APIAuth.generate_token(user.id)

        conn
        |> put_status(:created)
        |> json(%{
          token: token,
          user: %{
            id: user.id,
            username: user.username,
            email: "#{user.username}@elektrine.com",
            avatar: user.avatar,
            is_admin: false,
            inserted_at: user.inserted_at,
            updated_at: user.updated_at
          },
          message: "User registered successfully"
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        # Record failed attempt for rate limiting
        Elektrine.Auth.RateLimiter.record_attempt("register:#{remote_ip}")

        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Registration failed", errors: errors})
    end
  end

  @doc """
  GET /api/users/:id
  Gets a user by ID
  """
  def show(conn, %{"id" => id}) do
    try do
      user = Accounts.get_user!(id)

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
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  # Get remote IP with proxy header support
  defp get_remote_ip(conn) do
    real_ip = List.first(Plug.Conn.get_req_header(conn, "x-real-ip"))
    forwarded_for = List.first(Plug.Conn.get_req_header(conn, "x-forwarded-for"))
    remote_ip = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")

    real_ip ||
      if(forwarded_for, do: hd(String.split(forwarded_for, ",")) |> String.trim(), else: nil) ||
      remote_ip
  end
end
