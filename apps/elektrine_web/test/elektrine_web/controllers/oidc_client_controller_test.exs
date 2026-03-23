defmodule ElektrineWeb.OIDCClientControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.OAuth

  test "authenticated user can register and delete oidc clients", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    new_conn = get(conn, ~p"/account/developer/oidc/clients/new")
    assert html_response(new_conn, 200) =~ "Register OAuth Client"

    create_conn =
      post(conn, ~p"/account/developer/oidc/clients", %{
        "app" => %{
          "client_name" => "Terminal",
          "website" => "https://client.example",
          "redirect_uris" => "https://client.example/callback\nhttps://client.example/alt",
          "scopes" => ["openid", "profile", "email", "read"]
        }
      })

    assert redirected_to(create_conn) == "/account/developer/oidc/clients"

    [app] = OAuth.get_user_apps(user)
    assert app.client_name == "Terminal"

    assert OAuth.App.redirect_uri_list(app) == [
             "https://client.example/callback",
             "https://client.example/alt"
           ]

    index_conn = get(conn, ~p"/account/developer/oidc/clients")
    body = html_response(index_conn, 200)
    assert body =~ "Terminal"
    assert body =~ app.client_id

    delete_conn = delete(conn, ~p"/account/developer/oidc/clients/#{app.id}")
    assert redirected_to(delete_conn) == "/account/developer/oidc/clients"
    assert OAuth.get_user_apps(user) == []
  end

  test "authenticated user can edit and rotate a client secret", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, app} =
      OAuth.create_app(%{
        client_name: "Console",
        redirect_uris: "https://client.example/callback",
        scopes: ["openid", "profile"],
        user_id: user.id
      })

    edit_conn = get(conn, ~p"/account/developer/oidc/clients/#{app.id}/edit")
    assert html_response(edit_conn, 200) =~ "Edit OAuth Client"

    update_conn =
      put(conn, ~p"/account/developer/oidc/clients/#{app.id}", %{
        "app" => %{
          "client_name" => "Console Updated",
          "website" => "https://client.example",
          "redirect_uris" => "https://client.example/callback\nhttps://client.example/secondary",
          "scopes" => ["openid", "profile", "email"]
        }
      })

    assert redirected_to(update_conn) == "/account/developer/oidc/clients"
    updated_app = OAuth.get_user_app(user, app.id)
    assert updated_app.client_name == "Console Updated"
    assert updated_app.scopes == ["openid", "profile", "email"]

    old_secret = updated_app.client_secret

    rotate_conn = post(conn, ~p"/account/developer/oidc/clients/#{app.id}/rotate-secret", %{})
    assert redirected_to(rotate_conn) == "/account/developer/oidc/clients"

    rotated_app = OAuth.get_user_app(user, app.id)
    assert rotated_app.client_secret != old_secret
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
