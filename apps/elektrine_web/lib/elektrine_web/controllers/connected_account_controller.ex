defmodule ElektrineWeb.ConnectedAccountController do
  use ElektrineWeb, :controller

  alias Atomine.Personhood
  alias Elektrine.Accounts

  @github_authorize_url "https://github.com/login/oauth/authorize"
  @github_token_url "https://github.com/login/oauth/access_token"
  @github_user_url "https://api.github.com/user"
  @state_session_key "connected_account_oauth_state"
  @return_session_key "connected_account_oauth_return_to"

  def start(conn, %{"provider" => "github"} = params) do
    case github_config() do
      {:ok, client_id, _client_secret} ->
        state = random_state()
        return_to = safe_return_to(Map.get(params, "return_to"))

        query =
          URI.encode_query(%{
            client_id: client_id,
            redirect_uri: callback_url(conn, "github"),
            scope: "read:user user:email",
            state: state
          })

        conn
        |> put_session(@state_session_key, state)
        |> put_session(@return_session_key, return_to)
        |> redirect(external: @github_authorize_url <> "?" <> query)

      {:error, :missing_config} ->
        conn
        |> put_flash(:error, "GitHub OAuth is not configured.")
        |> redirect(to: ~p"/account/proofs")
    end
  end

  def start(conn, _params) do
    conn
    |> put_flash(:error, "Unsupported OAuth provider.")
    |> redirect(to: ~p"/account/proofs")
  end

  def callback(conn, %{"provider" => "github", "code" => code, "state" => state}) do
    expected_state = get_session(conn, @state_session_key)
    return_to = get_session(conn, @return_session_key) || ~p"/account/proofs"

    with true <- valid_state?(state, expected_state),
         {:ok, _client_id, client_secret} <- github_config(),
         {:ok, access_token} <- exchange_github_code(conn, code, client_secret),
         {:ok, github_user} <- fetch_github_user(access_token),
         {:ok, connected_account} <- upsert_github_account(conn.assigns.current_user, github_user),
         {:ok, _proof} <- Personhood.verify_connected_account_proof(connected_account) do
      conn
      |> delete_session(@state_session_key)
      |> delete_session(@return_session_key)
      |> put_flash(:info, "GitHub connected and proof verified.")
      |> redirect(to: return_to)
    else
      false ->
        oauth_error(conn, return_to, "GitHub connection failed: invalid OAuth state.")

      {:error, reason} ->
        oauth_error(conn, return_to, "GitHub connection failed: #{format_reason(reason)}.")
    end
  end

  def callback(conn, %{"provider" => "github", "error" => error}) do
    return_to = get_session(conn, @return_session_key) || ~p"/account/proofs"
    oauth_error(conn, return_to, "GitHub connection cancelled: #{error}.")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Unsupported OAuth callback.")
    |> redirect(to: ~p"/account/proofs")
  end

  defp exchange_github_code(conn, code, client_secret) do
    start_http_apps()
    {:ok, client_id, _client_secret} = github_config()

    body =
      URI.encode_query(%{
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: callback_url(conn, "github")
      })

    headers = [
      {~c"accept", ~c"application/json"},
      {~c"content-type", ~c"application/x-www-form-urlencoded"},
      {~c"user-agent", ~c"Elektrine"}
    ]

    case :httpc.request(
           :post,
           {@github_token_url, headers, ~c"application/x-www-form-urlencoded", body},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
          {:ok, %{"error" => error}} -> {:error, error}
          _ -> {:error, :invalid_token_response}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_github_user(access_token) do
    start_http_apps()

    headers = [
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"authorization", String.to_charlist("Bearer " <> access_token)},
      {~c"user-agent", ~c"Elektrine"}
    ]

    case :httpc.request(:get, {@github_user_url, headers}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_github_account(user, github_user) do
    Accounts.upsert_connected_account(user, %{
      provider: "github",
      provider_account_id: to_string(github_user["id"]),
      username: github_user["login"],
      display_name: github_user["name"],
      email: github_user["email"],
      profile_url: github_user["html_url"],
      avatar_url: github_user["avatar_url"],
      scopes: ["read:user", "user:email"],
      metadata: %{
        "company" => github_user["company"],
        "blog" => github_user["blog"],
        "location" => github_user["location"]
      }
    })
  end

  defp github_config do
    client_id = System.get_env("GITHUB_OAUTH_CLIENT_ID")
    client_secret = System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

    if present?(client_id) and present?(client_secret) do
      {:ok, client_id, client_secret}
    else
      {:error, :missing_config}
    end
  end

  defp callback_url(_conn, provider) do
    url(~p"/account/connections/#{provider}/callback")
  end

  defp start_http_apps do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    :ok
  end

  defp valid_state?(state, expected_state) when is_binary(state) and is_binary(expected_state) do
    Plug.Crypto.secure_compare(state, expected_state)
  end

  defp valid_state?(_, _), do: false

  defp random_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp safe_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      ~p"/account/proofs"
    end
  end

  defp safe_return_to(_), do: ~p"/account/proofs"

  defp oauth_error(conn, return_to, message) do
    conn
    |> delete_session(@state_session_key)
    |> delete_session(@return_session_key)
    |> put_flash(:error, message)
    |> redirect(to: return_to)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason(reason), do: inspect(reason)
end
