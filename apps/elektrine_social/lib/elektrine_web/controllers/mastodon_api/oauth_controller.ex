defmodule ElektrineWeb.MastodonAPI.OAuthController do
  @moduledoc """
  Controller for Mastodon API OAuth token management.

  Handles the OAuth 2.0 authorization code flow for Mastodon-compatible clients.

  ## Endpoints

  * `POST /oauth/token` - Exchange authorization code for access token
  * `POST /oauth/revoke` - Revoke an access token
  * `GET /oauth/authorize` - Authorization page (redirects to web UI)
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Passkeys
  alias Elektrine.API.RateLimiter, as: APIRateLimiter
  alias Elektrine.OAuth
  alias Elektrine.OAuth.Scopes
  alias Elektrine.OIDC
  alias ElektrineWeb.ClientIP

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
    params = Map.put(params, "_conn_authorization_header", get_req_header(conn, "authorization"))
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
    with {:ok, app} <-
           get_app_from_credentials(%{
             "client_id" => conn.params["client_id"],
             "client_secret" => conn.params["client_secret"],
             "_conn_authorization_header" => get_req_header(conn, "authorization")
           }),
         :ok <- OAuth.revoke_token(app, token) do
      json(conn, %{})
    else
      _ -> json(conn, %{})
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
         {:ok, auth} <- OAuth.consume_authorization(app, params["code"]),
         :ok <- validate_redirect_uri(auth, params),
         :ok <- validate_pkce(auth, params),
         {:ok, token} <- OAuth.exchange_token(app, auth) do
      render_token(conn, token, auth: auth, issuer: issuer(conn))
    else
      {:error, :not_found} -> {:error, :unprocessable_entity, "Invalid authorization code"}
      {:error, :redirect_uri_mismatch} -> {:error, :unprocessable_entity, "Invalid redirect_uri"}
      {:error, :invalid_grant} -> {:error, :unprocessable_entity, "Invalid code_verifier"}
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

      with :ok <- enforce_password_grant_rate_limit(conn, params),
           {:ok, app} <- get_app_from_credentials(params),
           {:ok, user} <- authenticate_user(params["username"], params["password"]),
           :ok <- ensure_password_grant_allowed(user),
           {:ok, token} <- OAuth.create_token(app, user, %{scopes: scopes}) do
        clear_password_grant_rate_limit(conn, params)
        render_token(conn, token)
      else
        {:error, :invalid_credentials} ->
          {:error, :unprocessable_entity, "Invalid username or password"}

        {:error, :second_factor_required} ->
          {:error, :unprocessable_entity,
           "Password grant is not allowed for accounts with 2FA or passkeys"}

        {:error, :invalid_scope} ->
          {:error, :unprocessable_entity, "Invalid scope"}

        {:error, :rate_limited} ->
          {:error, :too_many_requests, "Too many password grant attempts"}

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
      render_token(conn, token, issuer: issuer(conn))
    else
      nil -> {:error, :unprocessable_entity, "Missing refresh_token"}
      {:error, :not_found} -> {:error, :unprocessable_entity, "Invalid refresh token"}
      error -> error
    end
  end

  defp get_app_from_credentials(params) do
    client_id = params["client_id"]
    client_secret = params["client_secret"]

    {client_id, client_secret} =
      case basic_credentials(conn_auth_header(params)) do
        {basic_id, basic_secret} -> {client_id || basic_id, client_secret || basic_secret}
        _ -> {client_id, client_secret}
      end

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

  defp ensure_password_grant_allowed(user) do
    if user.two_factor_enabled || Passkeys.has_passkeys?(user) do
      {:error, :second_factor_required}
    else
      :ok
    end
  end

  defp enforce_password_grant_rate_limit(conn, params) do
    identifier = password_grant_rate_limit_key(conn, params)

    APIRateLimiter.record_attempt(identifier)

    case APIRateLimiter.check_rate_limit(identifier) do
      {:ok, _remaining} -> :ok
      {:error, _reason} -> {:error, :rate_limited}
    end
  end

  defp clear_password_grant_rate_limit(conn, params) do
    APIRateLimiter.clear_limits(password_grant_rate_limit_key(conn, params))
  end

  defp password_grant_rate_limit_key(conn, params) do
    username = to_string(params["username"] || "")
    "oauth_password_grant:#{ClientIP.rate_limit_ip(conn)}:#{String.downcase(username)}"
  end

  defp password_grant_enabled? do
    Application.get_env(:elektrine, :oauth_password_grant_enabled, false)
  end

  defp render_token(conn, token, opts \\ []) do
    expires_in = DateTime.diff(token.valid_until, DateTime.utc_now())

    response = %{
      access_token: OAuth.Token.access_token_value(token),
      token_type: "Bearer",
      scope: Scopes.to_string(token.scopes),
      created_at: DateTime.to_unix(token.inserted_at),
      expires_in: max(expires_in, 0),
      refresh_token: OAuth.Token.refresh_token_value(token)
    }

    response = maybe_put_id_token(response, token, opts)

    json(conn, response)
  end

  defp maybe_put_id_token(response, token, opts) do
    auth = Keyword.get(opts, :auth)
    issuer = Keyword.get(opts, :issuer)
    nonce = if auth, do: auth.nonce, else: token.oidc_nonce
    auth_time = if auth, do: auth.inserted_at, else: token.oidc_auth_time
    openid_token? = OIDC.openid_request?(token.scopes)
    has_user? = not is_nil(token.user)

    if openid_token? and has_user? and issuer do
      Map.put(
        response,
        :id_token,
        OIDC.issue_id_token(
          token,
          token.user,
          issuer,
          token.app.client_id,
          nonce,
          auth_time
        )
      )
    else
      response
    end
  end

  defp validate_redirect_uri(%{redirect_uri: nil}, _params), do: :ok

  defp validate_redirect_uri(%{redirect_uri: redirect_uri}, %{"redirect_uri" => redirect_uri}),
    do: :ok

  defp validate_redirect_uri(%{redirect_uri: redirect_uri}, params)
       when is_binary(redirect_uri) do
    if Map.get(params, "redirect_uri") in [nil, "", redirect_uri] do
      :ok
    else
      {:error, :redirect_uri_mismatch}
    end
  end

  defp validate_redirect_uri(_, _params), do: :ok

  defp validate_pkce(%{code_challenge: nil}, _params), do: :ok

  defp validate_pkce(%{code_challenge: challenge, code_challenge_method: method}, %{
         "code_verifier" => verifier
       })
       when is_binary(challenge) and is_binary(verifier) do
    case method || "plain" do
      "S256" -> if pkce_s256(verifier) == challenge, do: :ok, else: {:error, :invalid_grant}
      _ -> {:error, :invalid_grant}
    end
  end

  defp validate_pkce(%{code_challenge: _challenge}, _params), do: {:error, :invalid_grant}

  defp pkce_s256(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp issuer(conn) do
    conn
    |> url(~p"/")
    |> String.trim_trailing("/")
  end

  defp conn_auth_header(params), do: Map.get(params, "_conn_authorization_header")

  defp basic_credentials(["Basic " <> encoded]) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- :binary.split(decoded, ":") do
      {client_id, client_secret}
    else
      _ -> nil
    end
  end

  defp basic_credentials(_), do: nil
end
