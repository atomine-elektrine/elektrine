defmodule ElektrineWeb.MastodonAPI.OAuthController do
  @moduledoc """
  Controller for Mastodon API OAuth token management.

  Handles the OAuth 2.0 authorization code flow for Mastodon-compatible clients.

  ## Endpoints

  * `POST /oauth/token` - Exchange authorization code for access token
  * `POST /oauth/revoke` - Revoke an access token
  * `GET /oauth/authorize` - Authorization page (redirects to web UI)
  """

  use ElektrineWeb, :controller

  alias Elektrine.OAuth
  alias Elektrine.OAuth.Scopes
  alias Elektrine.Accounts

  action_fallback(ElektrineWeb.MastodonAPI.FallbackController)

  @doc """
  POST /oauth/token

  Exchanges an authorization code for an access token, or handles other grant types.

  ## Supported Grant Types

  * `authorization_code` - Exchange auth code for token
  * `client_credentials` - App-only token (no user)
  * `password` - Direct username/password auth (if enabled)
  * `refresh_token` - Refresh an existing token
  """
  def token(conn, params) do
    grant_type = params["grant_type"]

    case grant_type do
      "authorization_code" -> handle_authorization_code(conn, params)
      "client_credentials" -> handle_client_credentials(conn, params)
      "password" -> handle_password_grant(conn, params)
      "refresh_token" -> handle_refresh_token(conn, params)
      _ -> {:error, :unprocessable_entity, "Invalid grant_type"}
    end
  end

  @doc """
  POST /oauth/revoke

  Revokes an access token.
  """
  def revoke(conn, %{"token" => token}) do
    case OAuth.revoke_token(token) do
      :ok -> json(conn, %{})
      {:error, :not_found} -> json(conn, %{})
    end
  end

  def revoke(conn, _params) do
    json(conn, %{})
  end

  @doc """
  GET /oauth/authorize

  Shows the authorization page for the user to approve the app.
  This redirects to the web UI which handles the actual authorization.
  """
  def authorize(conn, params) do
    # Build the authorization URL for the web UI
    query = URI.encode_query(params)
    redirect(conn, to: "/oauth/authorize?#{query}")
  end

  # Private functions - Grant type handlers

  defp handle_authorization_code(conn, params) do
    with {:ok, app} <- get_app_from_credentials(params),
         {:ok, auth} <- OAuth.get_authorization(app, params["code"]),
         {:ok, token} <- OAuth.exchange_token(app, auth) do
      render_token(conn, token)
    else
      {:error, :not_found} -> {:error, :unprocessable_entity, "Invalid authorization code"}
      error -> error
    end
  end

  defp handle_client_credentials(conn, params) do
    scopes = Scopes.fetch_scopes(params, ["read"])

    with {:ok, app} <- get_app_from_credentials(params),
         {:ok, token} <- OAuth.create_token(app, nil, %{scopes: scopes}) do
      render_token(conn, token)
    end
  end

  defp handle_password_grant(conn, params) do
    # Password grant type - authenticate user directly
    # This is disabled by default for security, but some clients require it
    if password_grant_enabled?() do
      scopes = Scopes.fetch_scopes(params, ["read"])

      with {:ok, app} <- get_app_from_credentials(params),
           {:ok, user} <- authenticate_user(params["username"], params["password"]),
           {:ok, token} <- OAuth.create_token(app, user, %{scopes: scopes}) do
        render_token(conn, token)
      else
        {:error, :invalid_credentials} ->
          {:error, :unprocessable_entity, "Invalid username or password"}

        error ->
          error
      end
    else
      {:error, :unprocessable_entity, "Password grant type is disabled"}
    end
  end

  defp handle_refresh_token(conn, params) do
    with {:ok, app} <- get_app_from_credentials(params),
         refresh_token when is_binary(refresh_token) <- params["refresh_token"],
         {:ok, token} <- OAuth.refresh_token(app, refresh_token) do
      render_token(conn, token)
    else
      nil -> {:error, :unprocessable_entity, "Missing refresh_token"}
      {:error, :not_found} -> {:error, :unprocessable_entity, "Invalid refresh token"}
      error -> error
    end
  end

  defp get_app_from_credentials(params) do
    client_id = params["client_id"]
    client_secret = params["client_secret"]

    cond do
      is_nil(client_id) or is_nil(client_secret) ->
        {:error, :unprocessable_entity, "Missing client_id or client_secret"}

      app = OAuth.get_app_by_credentials(client_id, client_secret) ->
        {:ok, app}

      true ->
        {:error, :unprocessable_entity, "Invalid client credentials"}
    end
  end

  defp authenticate_user(username, password) when is_binary(username) and is_binary(password) do
    case Accounts.get_user_by_username(username) do
      nil ->
        # Prevent timing attacks
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        case Elektrine.Accounts.Authentication.verify_user_password(user, password) do
          {:ok, _user} -> {:ok, user}
          {:error, _} -> {:error, :invalid_credentials}
        end
    end
  end

  defp authenticate_user(_, _), do: {:error, :invalid_credentials}

  defp password_grant_enabled? do
    Application.get_env(:elektrine, :oauth_password_grant_enabled, false)
  end

  defp render_token(conn, token) do
    expires_in = DateTime.diff(token.valid_until, DateTime.utc_now())

    json(conn, %{
      access_token: token.token,
      token_type: "Bearer",
      scope: Scopes.to_string(token.scopes),
      created_at: DateTime.to_unix(token.inserted_at),
      expires_in: max(expires_in, 0),
      refresh_token: token.refresh_token
    })
  end
end
