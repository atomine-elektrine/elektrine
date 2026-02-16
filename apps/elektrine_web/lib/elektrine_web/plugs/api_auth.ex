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
  alias Elektrine.Auth.APITokenRevocation
  alias Elektrine.Repo
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

  @doc """
  Revokes a single API token so it cannot be used after logout.
  """
  def revoke_token(token) when is_binary(token) do
    with {:ok, %{data: data, timestamp: timestamp, signature: signature}} <- parse_token(token),
         true <- verify_signature(data, signature),
         {:ok, expires_at} <- DateTime.from_unix(timestamp + @max_token_age) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %APITokenRevocation{}
      |> APITokenRevocation.changeset(%{
        token_hash: token_hash(token),
        revoked_at: now,
        expires_at: DateTime.truncate(expires_at, :second)
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: :token_hash)
      |> case do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :revocation_failed}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def revoke_token(_), do: {:error, :invalid_token}

  defp verify_token(token) do
    with {:ok, %{user_id: user_id, timestamp: timestamp, signature: signature, data: data}} <-
           parse_token(token),
         true <- verify_signature(data, signature),
         false <- token_revoked?(token) do
      now = System.system_time(:second)
      token_age = now - timestamp

      cond do
        token_age < 0 ->
          {:error, :invalid_token}

        token_age >= @max_token_age ->
          {:error, :token_expired}

        token_age >= @max_token_age - @refresh_threshold ->
          # Token is valid but should be refreshed (less than 7 days remaining)
          {:ok, user_id, true}

        true ->
          # Token is valid and doesn't need refresh yet
          {:ok, user_id, false}
      end
    else
      false -> {:error, :invalid_signature}
      true -> {:error, :token_revoked}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  defp parse_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token),
         [user_id, timestamp, signature] <- String.split(decoded, ":"),
         {user_id_int, ""} <- Integer.parse(user_id),
         {timestamp_int, ""} <- Integer.parse(timestamp),
         true <- timestamp_int > 0 do
      {:ok,
       %{
         user_id: user_id_int,
         timestamp: timestamp_int,
         signature: signature,
         data: "#{user_id}:#{timestamp}"
       }}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp parse_token(_), do: {:error, :invalid_token}

  defp sign_data(data) do
    secret = get_secret_key()

    :crypto.mac(:hmac, :sha256, secret, data)
    |> Base.url_encode64()
  end

  defp verify_signature(data, signature) do
    expected = sign_data(data)

    is_binary(signature) and
      byte_size(signature) == byte_size(expected) and
      Plug.Crypto.secure_compare(signature, expected)
  end

  defp token_revoked?(token) do
    case Repo.get_by(APITokenRevocation, token_hash: token_hash(token)) do
      %APITokenRevocation{expires_at: expires_at} ->
        DateTime.compare(expires_at, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  rescue
    _ ->
      # During rolling deploys before migration, fail open rather than 500.
      false
  end

  defp token_hash(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp get_secret_key do
    Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
  end
end
