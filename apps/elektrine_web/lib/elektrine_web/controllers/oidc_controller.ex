defmodule ElektrineWeb.OIDCController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts.Authentication
  alias Elektrine.Domains
  alias Elektrine.OAuth
  alias Elektrine.OAuth.App
  alias Elektrine.OAuth.Scopes
  alias Elektrine.OIDC
  alias Elektrine.OwnRoot
  alias Elektrine.Profiles
  alias ElektrineWeb.UserAuth

  def configuration(conn, _params) do
    json(conn, OIDC.discovery_document(issuer(conn)))
  end

  def jwks(conn, _params) do
    json(conn, OIDC.jwks())
  end

  def authorize(conn, params) do
    case authorization_request(params) do
      {:ok, request} ->
        case conn.assigns[:current_user] do
          nil ->
            conn
            |> put_session(:user_return_to, current_request_path(conn))
            |> redirect(to: Elektrine.Paths.login_path())

          user ->
            if trusted_app_for_user?(request.app, user) do
              redirect_with_code(conn, request, user)
            else
              render(conn, :authorize,
                app: request.app,
                scopes: request.scopes,
                params: request.params,
                current_user: user
              )
            end
        end

      {:error, redirect_uri, error, state} when is_binary(redirect_uri) ->
        redirect(conn, external: redirect_error_uri(redirect_uri, error, state))

      {:error, :invalid_request} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request"})
    end
  end

  def approve(conn, %{"decision" => "deny"} = params) do
    case authorization_request(params) do
      {:ok, request} ->
        redirect(conn,
          external: redirect_error_uri(request.redirect_uri, "access_denied", request.state)
        )

      {:error, :invalid_request} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request"})

      {:error, redirect_uri, error, state} when is_binary(redirect_uri) ->
        redirect(conn, external: redirect_error_uri(redirect_uri, error, state))
    end
  end

  def approve(conn, %{"decision" => "approve"} = params) do
    with {:ok, request} <- authorization_request(params),
         %{current_user: user} when not is_nil(user) <- conn.assigns do
      redirect_with_code(conn, request, user)
    else
      %{current_user: nil} ->
        conn
        |> put_session(:user_return_to, current_request_path(conn))
        |> redirect(to: Elektrine.Paths.login_path())

      {:error, redirect_uri, error, state} when is_binary(redirect_uri) ->
        redirect(conn, external: redirect_error_uri(redirect_uri, error, state))

      {:error, :invalid_request} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request"})
    end
  end

  def approve(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request"})
  end

  def token(conn, params) do
    params = Map.put(params, "_conn_authorization_header", get_req_header(conn, "authorization"))

    case params["grant_type"] do
      "authorization_code" -> token_authorization_code(conn, params)
      "refresh_token" -> token_refresh_token(conn, params)
      _ -> token_error(conn, :unprocessable_entity, "unsupported_grant_type")
    end
  end

  def userinfo(conn, _params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, oauth_token} <- OAuth.get_token(token),
         true <- OAuth.token_valid?(oauth_token),
         true <- OIDC.openid_request?(oauth_token.scopes),
         user when not is_nil(user) <- oauth_token.user,
         :ok <- Authentication.ensure_user_active(user),
         false <- oauth_token_older_than_auth_boundary?(user, oauth_token) do
      json(
        conn,
        OIDC.userinfo_claims(
          user,
          oauth_token.scopes,
          issuer(conn),
          token_identity_opts(oauth_token)
        )
      )
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})
    end
  end

  def dynamic_register(conn, params) do
    if recent_auth_valid?(conn) do
      attrs = %{
        client_name: params["client_name"] || params["application_name"],
        website: params["client_uri"] || params["website"],
        redirect_uris: normalize_redirect_uris(params["redirect_uris"]),
        scopes: normalize_scopes(params["scope"] || params["scopes"]),
        user_id: conn.assigns.current_user && conn.assigns.current_user.id
      }

      case OAuth.create_app(attrs) do
        {:ok, app} ->
          conn
          |> put_status(:created)
          |> json(%{
            client_id: app.client_id,
            client_secret: OAuth.App.client_secret_value(app),
            client_id_issued_at: DateTime.to_unix(app.inserted_at),
            client_secret_expires_at: 0,
            client_name: app.client_name,
            client_uri: app.website,
            redirect_uris: App.redirect_uri_list(app),
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "client_secret_basic",
            scope: Enum.join(app.scopes, " ")
          })

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_client_metadata", details: translate_errors(changeset)})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "recent_auth_required"})
    end
  end

  defp token_authorization_code(conn, params) do
    with {:ok, app} <- get_app_from_credentials(params),
         {:ok, auth} <- OAuth.get_authorization(app, params["code"]),
         :ok <- validate_token_redirect_uri(auth, params),
         :ok <- validate_token_pkce(auth, params),
         {:ok, auth} <- OAuth.consume_authorization(app, params["code"]),
         {:ok, token} <- OAuth.exchange_token(app, auth) do
      render_token(conn, token, auth: auth, issuer: issuer(conn))
    else
      {:error, :not_found} ->
        token_error(conn, :unprocessable_entity, "invalid_grant")

      {:error, :redirect_uri_mismatch} ->
        token_error(conn, :unprocessable_entity, "invalid_grant")

      {:error, :invalid_grant} ->
        token_error(conn, :unprocessable_entity, "invalid_grant")

      {:error, :invalid_client} ->
        token_error(conn, :unprocessable_entity, "invalid_client")

      error ->
        error
    end
  end

  defp token_refresh_token(conn, params) do
    with {:ok, app} <- get_app_from_credentials(params),
         refresh_token when is_binary(refresh_token) <- params["refresh_token"],
         {:ok, token} <- OAuth.refresh_token(app, refresh_token) do
      render_token(conn, token, issuer: issuer(conn))
    else
      nil -> token_error(conn, :unprocessable_entity, "invalid_grant")
      {:error, :not_found} -> token_error(conn, :unprocessable_entity, "invalid_grant")
      {:error, :invalid_client} -> token_error(conn, :unprocessable_entity, "invalid_client")
      error -> error
    end
  end

  defp get_app_from_credentials(params) do
    client_id = params["client_id"]
    client_secret = params["client_secret"]

    {client_id, client_secret} =
      case basic_credentials(params["_conn_authorization_header"]) do
        {basic_id, basic_secret} -> {client_id || basic_id, client_secret || basic_secret}
        _ -> {client_id, client_secret}
      end

    cond do
      is_nil(client_id) or is_nil(client_secret) ->
        {:error, :invalid_client}

      app = OAuth.get_app_by_credentials(client_id, client_secret) ->
        {:ok, app}

      true ->
        {:error, :invalid_client}
    end
  end

  defp render_token(conn, token, opts) do
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
          auth_time,
          token_identity_opts(token)
        )
      )
    else
      response
    end
  end

  defp token_error(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp redirect_with_code(conn, request, user) do
    identity_attrs = verified_identity_attrs(request.identity_domain, user)

    case OAuth.create_authorization(request.app, user, %{
           scopes: request.scopes,
           redirect_uri: request.redirect_uri,
           state: request.state,
           nonce: request.nonce,
           code_challenge: request.code_challenge,
           code_challenge_method: request.code_challenge_method,
           identity_subject: identity_attrs[:identity_subject],
           identity_domain: identity_attrs[:identity_domain],
           identity_did: identity_attrs[:identity_did]
         }) do
      {:ok, auth} ->
        redirect(
          conn,
          external:
            redirect_code_uri(
              request.redirect_uri,
              Elektrine.OAuth.Authorization.token_value(auth),
              request.state
            )
        )

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "server_error"})
    end
  end

  defp authorization_request(params) do
    with %{"client_id" => client_id, "response_type" => "code"} <- params,
         %App{} = app <- OAuth.get_app_by_client_id(client_id),
         {:ok, redirect_uri} <- resolve_redirect_uri(app, params["redirect_uri"]),
         scopes <- OAuth.fetch_scopes(params, app.scopes),
         true <- Enum.all?(scopes, &(&1 in app.scopes)),
         :ok <- validate_pkce(params, scopes) do
      {:ok,
       %{
         app: app,
         redirect_uri: redirect_uri,
         scopes: scopes,
         state: params["state"],
         nonce: params["nonce"],
         identity_domain: normalize_identity_domain(params["identity_domain"]),
         code_challenge: blank_to_nil(params["code_challenge"]),
         code_challenge_method: blank_to_nil(params["code_challenge_method"]),
         params: Map.put(params, "redirect_uri", redirect_uri)
       }}
    else
      nil -> {:error, :invalid_request}
      false -> invalid_scope_error(params)
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp resolve_redirect_uri(app, nil), do: resolve_redirect_uri(app, "")

  defp resolve_redirect_uri(%App{} = app, redirect_uri) do
    trimmed = String.trim(to_string(redirect_uri || ""))

    cond do
      trimmed != "" and App.redirect_uri_allowed?(app, trimmed) ->
        {:ok, trimmed}

      trimmed == "" and is_binary(App.default_redirect_uri(app)) ->
        {:ok, App.default_redirect_uri(app)}

      true ->
        {:error, :invalid_request}
    end
  end

  defp validate_pkce(params, _scopes) do
    validate_required_pkce(params)
  end

  defp recent_auth_valid?(conn) do
    conn
    |> get_session(UserAuth.recent_auth_session_key())
    |> UserAuth.recent_auth_valid?()
  end

  defp validate_required_pkce(params) do
    code_challenge = blank_to_nil(params["code_challenge"])
    code_challenge_method = blank_to_nil(params["code_challenge_method"])

    cond do
      is_nil(code_challenge) -> invalid_request_error(params)
      code_challenge_method in [nil, "S256"] -> :ok
      true -> invalid_request_error(params)
    end
  end

  defp verified_identity_attrs(nil, _user), do: %{}

  defp verified_identity_attrs(identity_domain, %{id: user_id})
       when is_binary(identity_domain) and is_integer(user_id) do
    case Profiles.get_verified_custom_domain(identity_domain) do
      %{domain: domain, user_id: ^user_id} ->
        %{
          identity_subject: OwnRoot.subject(domain),
          identity_domain: domain,
          identity_did: OwnRoot.did_for_domain(domain)
        }

      _ ->
        verified_builtin_identity_attrs(identity_domain, user_id)
    end
  end

  defp verified_identity_attrs(_, _), do: %{}

  defp verified_builtin_identity_attrs(identity_domain, user_id) do
    case Domains.profile_base_domain_for_host(identity_domain) do
      nil ->
        %{}

      base_domain ->
        suffix = "." <> base_domain
        handle = String.trim_trailing(identity_domain, suffix)

        with true <- handle != "" and not String.contains?(handle, "."),
             %{id: ^user_id} <- Elektrine.Accounts.get_user_by_handle(handle) do
          %{
            identity_subject: OwnRoot.subject(identity_domain),
            identity_domain: identity_domain,
            identity_did: OwnRoot.did_for_domain(identity_domain)
          }
        else
          _ -> %{}
        end
    end
  end

  defp token_identity_opts(token) do
    [
      subject: blank_to_nil(Map.get(token, :identity_subject)),
      identity_domain: blank_to_nil(Map.get(token, :identity_domain)),
      identity_did: blank_to_nil(Map.get(token, :identity_did))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_identity_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("https://")
    |> String.trim_leading("http://")
    |> String.trim_trailing("/")
    |> String.trim_trailing(".")
    |> blank_to_nil()
  end

  defp normalize_identity_domain(_), do: nil

  defp validate_token_redirect_uri(%{redirect_uri: nil}, _params), do: :ok

  defp validate_token_redirect_uri(%{redirect_uri: redirect_uri}, %{
         "redirect_uri" => redirect_uri
       }),
       do: :ok

  defp validate_token_redirect_uri(%{redirect_uri: redirect_uri}, params)
       when is_binary(redirect_uri) do
    if Map.get(params, "redirect_uri") in [nil, "", redirect_uri] do
      :ok
    else
      {:error, :redirect_uri_mismatch}
    end
  end

  defp validate_token_redirect_uri(_, _params), do: :ok

  defp validate_token_pkce(%{code_challenge: nil}, _params), do: :ok

  defp validate_token_pkce(%{code_challenge: challenge, code_challenge_method: method}, %{
         "code_verifier" => verifier
       })
       when is_binary(challenge) and is_binary(verifier) do
    case method || "plain" do
      "S256" -> if pkce_s256(verifier) == challenge, do: :ok, else: {:error, :invalid_grant}
      _ -> {:error, :invalid_grant}
    end
  end

  defp validate_token_pkce(%{code_challenge: _challenge}, _params), do: {:error, :invalid_grant}

  defp pkce_s256(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp invalid_scope_error(params) do
    case safe_error_redirect_uri(params) do
      {:ok, redirect_uri} -> {:error, redirect_uri, "invalid_scope", params["state"]}
      :error -> {:error, :invalid_request}
    end
  end

  defp invalid_request_error(params) do
    case safe_error_redirect_uri(params) do
      {:ok, redirect_uri} -> {:error, redirect_uri, "invalid_request", params["state"]}
      :error -> {:error, :invalid_request}
    end
  end

  defp safe_error_redirect_uri(%{"client_id" => client_id} = params) do
    with %App{} = app <- OAuth.get_app_by_client_id(client_id),
         {:ok, redirect_uri} <- resolve_redirect_uri(app, params["redirect_uri"]) do
      {:ok, redirect_uri}
    else
      _ -> :error
    end
  end

  defp safe_error_redirect_uri(_params), do: :error

  defp redirect_code_uri(redirect_uri, code, state) do
    redirect_uri
    |> URI.parse()
    |> merge_query(%{"code" => code, "state" => state})
    |> URI.to_string()
  end

  defp redirect_error_uri(redirect_uri, error, state) do
    redirect_uri
    |> URI.parse()
    |> merge_query(%{"error" => error, "state" => state})
    |> URI.to_string()
  end

  defp merge_query(%URI{} = uri, params) do
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}

    query =
      existing
      |> Map.merge(Enum.reject(params, fn {_k, v} -> is_nil(v) or v == "" end) |> Map.new())

    %{uri | query: URI.encode_query(query)}
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp issuer(conn) do
    conn
    |> url(~p"/")
    |> String.trim_trailing("/")
  end

  defp current_request_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp basic_credentials(["Basic " <> encoded]) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- :binary.split(decoded, ":") do
      {client_id, client_secret}
    else
      _ -> nil
    end
  end

  defp basic_credentials(_), do: nil

  defp normalize_redirect_uris(value) when is_list(value), do: Enum.join(value, " ")
  defp normalize_redirect_uris(value) when is_binary(value), do: value
  defp normalize_redirect_uris(_), do: ""

  defp normalize_scopes(value) when is_binary(value),
    do: OAuth.parse_scopes(value, ["openid", "profile", "email", "read"])

  defp normalize_scopes(value) when is_list(value), do: Enum.reject(value, &(&1 in [nil, ""]))
  defp normalize_scopes(_), do: ["openid", "profile", "email", "read"]

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp trusted_app_for_user?(%{trusted: true, user_id: owner_id}, user) do
    is_nil(owner_id) or owner_id == user.id
  end

  defp trusted_app_for_user?(_app, _user), do: false

  defp oauth_token_older_than_auth_boundary?(user, oauth_token) do
    case user.auth_valid_after do
      %DateTime{} = valid_after -> DateTime.compare(oauth_token.inserted_at, valid_after) == :lt
      _ -> false
    end
  end
end
