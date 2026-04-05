defmodule ElektrineWeb.OIDCControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.OAuth
  alias Elektrine.OAuth.App

  @pkce_verifier "challenge-123"
  @pkce_challenge :crypto.hash(:sha256, @pkce_verifier) |> Base.url_encode64(padding: false)

  describe "openid configuration" do
    test "serves discovery metadata", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/.well-known/openid-configuration")

      assert %{
               "authorization_endpoint" => authorization_endpoint,
               "jwks_uri" => jwks_uri,
               "token_endpoint" => token_endpoint,
               "userinfo_endpoint" => userinfo_endpoint,
               "scopes_supported" => scopes_supported
             } = json_response(conn, 200)

      assert authorization_endpoint =~ "/oauth/authorize"
      assert jwks_uri =~ "/oauth/jwks"
      assert token_endpoint =~ "/oauth/token"
      assert userinfo_endpoint =~ "/oauth/userinfo"
      assert "openid" in scopes_supported
    end

    test "serves jwks metadata", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/oauth/jwks")

      assert %{
               "keys" => [
                 %{"alg" => "RS256", "e" => _e, "kid" => _kid, "kty" => "RSA", "n" => _n}
               ]
             } =
               json_response(conn, 200)
    end
  end

  describe "authorization code flow" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      {:ok, app} =
        OAuth.create_app(%{
          client_name: "Console",
          redirect_uris: "https://client.example/callback",
          scopes: ["openid", "profile"]
        })

      conn =
        get(
          conn,
          ~p"/oauth/authorize?client_id=#{app.client_id}&redirect_uri=https://client.example/callback&response_type=code&scope=openid%20profile&state=state-123&code_challenge=#{@pkce_challenge}&code_challenge_method=S256"
        )

      assert redirected_to(conn) == "/login"
    end

    test "issues id_token and userinfo for openid clients", %{conn: conn} do
      user = user_fixture(%{username: "oidcuser"})

      {:ok, app} =
        OAuth.create_app(%{
          client_name: "Citizen Console",
          redirect_uris: "https://client.example/callback",
          scopes: ["openid", "profile", "email"]
        })

      conn = log_in_user(conn, user)

      authorize_conn =
        get(
          conn,
          ~p"/oauth/authorize?client_id=#{app.client_id}&redirect_uri=https://client.example/callback&response_type=code&scope=openid%20profile%20email&state=state-123&nonce=nonce-abc&code_challenge=#{@pkce_challenge}&code_challenge_method=S256"
        )

      assert html_response(authorize_conn, 200) =~ "Citizen Console"

      approval_conn =
        post(conn, ~p"/oauth/authorize", %{
          "decision" => "approve",
          "client_id" => app.client_id,
          "redirect_uri" => "https://client.example/callback",
          "response_type" => "code",
          "scope" => "openid profile email",
          "state" => "state-123",
          "nonce" => "nonce-abc",
          "code_challenge" => @pkce_challenge,
          "code_challenge_method" => "S256"
        })

      redirect_url = redirected_to(approval_conn, 302)
      %URI{query: query} = URI.parse(redirect_url)
      %{"code" => code, "state" => "state-123"} = URI.decode_query(query)

      token_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => App.client_secret_value(app),
          "code" => code,
          "redirect_uri" => "https://client.example/callback",
          "code_verifier" => @pkce_verifier
        })

      assert %{
               "access_token" => access_token,
               "id_token" => id_token,
               "refresh_token" => refresh_token,
               "scope" => "openid profile email"
             } = json_response(token_conn, 200)

      expected_aud = app.client_id

      assert %{"aud" => ^expected_aud, "nonce" => "nonce-abc", "sub" => sub} =
               decode_jwt_payload(id_token)

      userinfo_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get(~p"/oauth/userinfo")

      assert %{
               "sub" => ^sub,
               "preferred_username" => preferred_username,
               "email" => email,
               "email_verified" => false
             } = json_response(userinfo_conn, 200)

      assert preferred_username == user.handle
      assert email =~ "@"

      refresh_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "client_id" => app.client_id,
          "client_secret" => App.client_secret_value(app),
          "refresh_token" => refresh_token
        })

      assert %{"id_token" => refreshed_id_token, "access_token" => refreshed_access_token} =
               json_response(refresh_conn, 200)

      assert refreshed_access_token != access_token
      assert %{"aud" => ^expected_aud, "sub" => ^sub} = decode_jwt_payload(refreshed_id_token)
    end
  end

  describe "dynamic client registration" do
    test "authenticated user can register clients over oauth endpoint", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      register_conn =
        conn
        |> put_req_header("accept", "application/json")
        |> post(~p"/oauth/register", %{
          "client_name" => "CLI App",
          "client_uri" => "https://cli.example",
          "redirect_uris" => ["https://cli.example/callback"],
          "scope" => "openid profile email"
        })

      assert %{
               "client_id" => _client_id,
               "client_secret" => _client_secret,
               "client_name" => "CLI App",
               "redirect_uris" => ["https://cli.example/callback"],
               "token_endpoint_auth_method" => "client_secret_basic"
             } = json_response(register_conn, 201)
    end
  end

  test "rejects authorization requests without pkce", %{conn: conn} do
    user = user_fixture(%{username: "oidcnopkce"})

    {:ok, app} =
      OAuth.create_app(%{
        client_name: "No PKCE",
        redirect_uris: "https://client.example/callback",
        scopes: ["openid", "profile"]
      })

    conn = log_in_user(conn, user)

    conn =
      get(
        conn,
        ~p"/oauth/authorize?client_id=#{app.client_id}&redirect_uri=https://client.example/callback&response_type=code&scope=openid%20profile"
      )

    assert json_response(conn, 400) == %{"error" => "invalid_request"}
  end

  test "rejects insecure redirect uris during registration" do
    assert {:error, changeset} =
             OAuth.create_app(%{
               client_name: "Insecure Console",
               redirect_uris: "http://client.example/callback",
               scopes: ["openid"]
             })

    assert "contains invalid URI" in errors_on(changeset).redirect_uris
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp decode_jwt_payload(token) do
    [_header, payload, _signature] = String.split(token, ".")
    {:ok, decoded} = Base.url_decode64(payload, padding: false)
    Jason.decode!(decoded)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
