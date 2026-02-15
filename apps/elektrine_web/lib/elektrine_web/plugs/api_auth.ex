defmodule ElektrineWeb.Plugs.APIAuth do
  @moduledoc """
  Plug for API token-based authentication.
  Used for mobile app and API access.

  Features:
  - Token-based authentication with HMAC signatures
  - Sliding window token refresh (tokens refreshed when < 7 days remaining)
  - 30-day maximum token lifetime
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Accounts
  alias Elektrine.Telemetry.Events

  # Token expires after 30 days
  @max_token_age 30 * 24 * 60 * 60
  # Refresh token if less than 7 days remaining
  @refresh_threshold 7 * 24 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case verify_token(token) do
          {:ok, user_id, should_refresh} ->
            try do
              user = Accounts.get_user!(user_id)
              Events.auth(:api_token, :success, %{reason: :token_valid})
              conn = assign(conn, :current_user, user)

              # Sliding window: refresh token if close to expiration
              if should_refresh do
                {:ok, new_token} = generate_token(user_id)
                put_resp_header(conn, "x-refreshed-token", new_token)
              else
                conn
              end
            rescue
              Ecto.NoResultsError ->
                Events.auth(:api_token, :failure, %{reason: :user_not_found})

                conn
                |> put_status(:unauthorized)
                |> put_view(json: ElektrineWeb.ErrorJSON)
                |> render(:"401")
                |> halt()
            end

          {:error, _reason} ->
            Events.auth(:api_token, :failure, %{reason: :token_invalid})

            conn
            |> put_status(:unauthorized)
            |> put_view(json: ElektrineWeb.ErrorJSON)
            |> render(:"401")
            |> halt()
        end

      _ ->
        Events.auth(:api_token, :failure, %{reason: :missing_token})

        conn
        |> put_status(:unauthorized)
        |> put_view(json: ElektrineWeb.ErrorJSON)
        |> render(:"401")
        |> halt()
    end
  end

  @doc """
  Generates a JWT token for a user
  """
  def generate_token(user_id) do
    # Simple token format: base64(user_id:timestamp:signature)
    timestamp = System.system_time(:second)
    data = "#{user_id}:#{timestamp}"
    signature = sign_data(data)
    token = Base.url_encode64("#{data}:#{signature}")
    {:ok, token}
  end

  @doc """
  Verifies an API token and returns the user_id.
  This is exposed for use by WebSocket authentication.
  Returns {:ok, user_id} or {:error, reason}
  """
  def verify_token_internal(token) do
    case verify_token(token) do
      {:ok, user_id, _should_refresh} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_token(token) do
    case Base.url_decode64(token) do
      {:ok, decoded} ->
        case String.split(decoded, ":") do
          [user_id, timestamp, signature] ->
            data = "#{user_id}:#{timestamp}"

            if verify_signature(data, signature) do
              timestamp_int = String.to_integer(timestamp)
              now = System.system_time(:second)
              token_age = now - timestamp_int

              cond do
                token_age >= @max_token_age ->
                  {:error, :token_expired}

                token_age >= @max_token_age - @refresh_threshold ->
                  # Token is valid but should be refreshed (less than 7 days remaining)
                  {:ok, String.to_integer(user_id), true}

                true ->
                  # Token is valid and doesn't need refresh yet
                  {:ok, String.to_integer(user_id), false}
              end
            else
              {:error, :invalid_signature}
            end

          _ ->
            {:error, :invalid_format}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  defp sign_data(data) do
    secret = get_secret_key()

    :crypto.mac(:hmac, :sha256, secret, data)
    |> Base.url_encode64()
  end

  defp verify_signature(data, signature) do
    expected = sign_data(data)
    Plug.Crypto.secure_compare(signature, expected)
  end

  defp get_secret_key do
    Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
  end
end
