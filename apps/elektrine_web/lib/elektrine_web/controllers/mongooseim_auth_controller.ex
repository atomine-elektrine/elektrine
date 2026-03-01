defmodule ElektrineWeb.MongooseIMAuthController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
  alias Elektrine.Auth.RateLimiter, as: AuthRateLimiter

  @doc """
  Compatibility endpoint for MongooseIM HTTP auth backends.

  Supported credential payloads:
  - `%{"username" => "...", "password" => "..."}`
  - `%{"user" => "...", "pass" => "..."}`
  - `%{"user" => %{"id" => "...", "password" => "..."}}`

  Returns plain-text `"true"` or `"false"` with HTTP 200.
  """
  def check_credentials(conn, params) when is_map(params) do
    text(conn, authenticate_response(params))
  end

  @doc """
  MongooseIM `check_password` compatibility endpoint.
  """
  def check_password(conn, params) when is_map(params) do
    text(conn, authenticate_response(params))
  end

  @doc """
  MongooseIM `user_exists` compatibility endpoint.
  """
  def user_exists(conn, params) when is_map(params) do
    response =
      case extract_username(params) do
        {:ok, username} ->
          if Accounts.get_user_by_username(username), do: "true", else: "false"

        _ ->
          "false"
      end

    text(conn, response)
  end

  defp authenticate_response(params) when is_map(params) do
    with {:ok, username} <- extract_username(params),
         {:ok, password} <- extract_password(params) do
      limiter_key = mongooseim_auth_rate_limit_key(username)

      case AuthRateLimiter.check_rate_limit(limiter_key) do
        {:ok, :allowed} ->
          case authenticate_mongooseim_user(username, password) do
            {:ok, _user} ->
              AuthRateLimiter.clear_limits(limiter_key)
              "true"

            {:error, _reason} ->
              AuthRateLimiter.record_attempt(limiter_key)
              "false"
          end

        {:error, {:rate_limited, _retry_after, _reason}} ->
          "false"
      end
    else
      _ ->
        "false"
    end
  end

  defp extract_username(params) do
    params
    |> extract_username_candidate()
    |> normalize_localpart()
  end

  defp extract_username_candidate(%{"username" => username}) when is_binary(username),
    do: username

  defp extract_username_candidate(%{"user" => username}) when is_binary(username), do: username

  defp extract_username_candidate(%{"user" => %{"id" => user_id}}) when is_binary(user_id),
    do: user_id

  defp extract_username_candidate(_), do: nil

  defp extract_password(%{"password" => password}) when is_binary(password) and password != "",
    do: {:ok, password}

  defp extract_password(%{"pass" => password}) when is_binary(password) and password != "",
    do: {:ok, password}

  defp extract_password(%{"user" => %{"password" => password}})
       when is_binary(password) and password != "",
       do: {:ok, password}

  defp extract_password(_), do: {:error, :missing_password}

  defp normalize_localpart(candidate) when is_binary(candidate) do
    localpart =
      candidate
      |> String.trim()
      |> String.trim_leading("@")
      |> String.split(":", parts: 2)
      |> List.first()
      |> to_string()
      |> String.split("@", parts: 2)
      |> List.first()
      |> String.trim()

    if localpart == "", do: {:error, :missing_username}, else: {:ok, localpart}
  end

  defp normalize_localpart(_), do: {:error, :missing_username}

  defp mongooseim_auth_rate_limit_key(localpart) when is_binary(localpart) do
    "mongooseim_auth:#{String.downcase(localpart)}"
  end

  # Matches DAV/JMAP/Matrix internal auth behavior:
  # - app password first
  # - regular password fallback only when 2FA is disabled
  defp authenticate_mongooseim_user(username, password) do
    case Accounts.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        {:ok, user}

      {:error, {:invalid_token, user}} ->
        if user.two_factor_enabled do
          {:error, :requires_app_password}
        else
          case Authentication.verify_user_password(user, password) do
            {:ok, _user} -> {:ok, user}
            {:error, _reason} -> {:error, :invalid_credentials}
          end
        end

      {:error, :user_not_found} ->
        # Keep timing similar between existing/non-existing users.
        Argon2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end
end
