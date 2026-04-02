defmodule ElektrineWeb.OIDCController do
  use ElektrineWeb, :controller

  alias Elektrine.OAuth
  alias Elektrine.OAuth.App
  alias Elektrine.OIDC

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
            |> redirect(to: ~p"/login")

          user ->
            if request.app.trusted do
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
        |> redirect(to: ~p"/login")

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

  def userinfo(conn, _params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, oauth_token} <- OAuth.get_token(token),
         true <- OAuth.token_valid?(oauth_token),
         true <- OIDC.openid_request?(oauth_token.scopes),
         user when not is_nil(user) <- oauth_token.user do
      json(conn, OIDC.userinfo_claims(user, oauth_token.scopes, issuer(conn)))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})
    end
  end

  def dynamic_register(conn, params) do
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
          client_secret: app.client_secret,
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
  end

  defp redirect_with_code(conn, request, user) do
    case OAuth.create_authorization(request.app, user, %{
           scopes: request.scopes,
           redirect_uri: request.redirect_uri,
           state: request.state,
           nonce: request.nonce,
           code_challenge: request.code_challenge,
           code_challenge_method: request.code_challenge_method
         }) do
      {:ok, auth} ->
        redirect(conn,
          external: redirect_code_uri(request.redirect_uri, auth.token, request.state)
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
         :ok <- validate_pkce(params) do
      {:ok,
       %{
         app: app,
         redirect_uri: redirect_uri,
         scopes: scopes,
         state: params["state"],
         nonce: params["nonce"],
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

  defp validate_pkce(%{"code_challenge_method" => method} = params)
       when method in ["plain", "S256"] do
    if blank_to_nil(params["code_challenge"]) do
      :ok
    else
      invalid_request_error(params)
    end
  end

  defp validate_pkce(%{"code_challenge" => code_challenge} = params) do
    if blank_to_nil(code_challenge) do
      invalid_request_error(params)
    else
      :ok
    end
  end

  defp validate_pkce(%{
         "code_challenge_method" => _invalid,
         "redirect_uri" => redirect_uri,
         "state" => state
       }),
       do: invalid_request_error(%{"redirect_uri" => redirect_uri, "state" => state})

  defp validate_pkce(_params), do: invalid_request_error(%{})

  defp invalid_scope_error(params) do
    redirect_uri = params["redirect_uri"] || ""

    if redirect_uri == "" do
      {:error, :invalid_request}
    else
      {:error, redirect_uri, "invalid_scope", params["state"]}
    end
  end

  defp invalid_request_error(params) do
    redirect_uri = blank_to_nil(params["redirect_uri"])

    if redirect_uri do
      {:error, redirect_uri, "invalid_request", params["state"]}
    else
      {:error, :invalid_request}
    end
  end

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
end
