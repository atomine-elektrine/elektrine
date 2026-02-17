defmodule ElektrineWeb.MatrixInternalAuthController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
  alias Elektrine.ActivityPub
  alias Elektrine.Auth.RateLimiter, as: AuthRateLimiter

  @doc """
  Compatibility endpoint for matrix-synapse-rest-password-provider.

  POST /_matrix-internal/identity/v1/check_credentials
  """
  def check_credentials(conn, %{"user" => %{"id" => user_id, "password" => password}})
      when is_binary(user_id) and is_binary(password) do
    localpart = extract_localpart(user_id)

    response =
      if is_binary(localpart) do
        limiter_key = matrix_auth_rate_limit_key(localpart)

        case AuthRateLimiter.check_rate_limit(limiter_key) do
          {:ok, :allowed} ->
            case authenticate_matrix_user(localpart, password) do
              {:ok, user} ->
                AuthRateLimiter.clear_limits(limiter_key)

                %{
                  auth: %{
                    success: true,
                    mxid: matrix_id_for_username(user.username),
                    profile: %{
                      display_name: user.username,
                      three_pids: []
                    }
                  }
                }

              {:error, _reason} ->
                AuthRateLimiter.record_attempt(limiter_key)
                %{auth: %{success: false}}
            end

          {:error, {:rate_limited, _retry_after, _reason}} ->
            %{auth: %{success: false}}
        end
      else
        %{auth: %{success: false}}
      end

    json(conn, response)
  end

  def check_credentials(conn, _params) do
    json(conn, %{auth: %{success: false}})
  end

  defp extract_localpart(user_id) when is_binary(user_id) do
    candidate =
      user_id
      |> String.trim()
      |> String.trim_leading("@")
      |> String.split(":", parts: 2)
      |> List.first()

    if is_binary(candidate) and candidate != "", do: candidate, else: nil
  end

  defp matrix_id_for_username(username) when is_binary(username) do
    "@#{username}:#{ActivityPub.instance_domain()}"
  end

  defp matrix_auth_rate_limit_key(localpart) when is_binary(localpart) do
    "matrix_auth:#{String.downcase(localpart)}"
  end

  # Matches DAV/JMAP auth behavior:
  # - app password first
  # - regular password fallback only when 2FA is disabled
  defp authenticate_matrix_user(username, password) do
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
