defmodule ElektrineWeb.OIDCGrantControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.OAuth

  test "user can review and revoke granted apps", %{conn: conn} do
    user = user_fixture(%{username: "grantuser"})

    {:ok, app} =
      OAuth.create_app(%{
        client_name: "Grant App",
        redirect_uris: "https://client.example/callback",
        scopes: ["openid", "profile", "email"],
        user_id: user.id
      })

    {:ok, auth} =
      OAuth.create_authorization(app, user, %{
        scopes: ["openid", "profile", "email"],
        redirect_uri: "https://client.example/callback",
        nonce: "nonce"
      })

    {:ok, _token} = OAuth.exchange_token(app, auth)

    conn = log_in_user(conn, user)

    index_conn = get(conn, ~p"/account/developer/oidc/grants")
    body = html_response(index_conn, 200)
    assert body =~ "Grant App"
    assert body =~ "openid"

    revoke_conn = delete(conn, ~p"/account/developer/oidc/grants/#{app.id}")
    assert redirected_to(revoke_conn) == "/account/developer/oidc/grants"
    assert OAuth.get_user_tokens(user) == []
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
