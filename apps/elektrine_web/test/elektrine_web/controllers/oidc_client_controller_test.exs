defmodule ElektrineWeb.OIDCClientControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.OAuth
  alias ElektrineWeb.UserAuth

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

    revealed_secret = Phoenix.Flash.get(create_conn.assigns.flash, :client_secret)
    assert is_binary(revealed_secret)
    refute revealed_secret == app.client_secret

    index_conn = get(create_conn, ~p"/account/developer/oidc/clients")
    body = html_response(index_conn, 200)
    assert body =~ "Terminal"
    assert body =~ app.client_id
    assert body =~ revealed_secret
    assert body =~ OAuth.App.client_secret_fingerprint(app)
    refute body =~ app.client_secret

    persistent_index_conn = get(conn, ~p"/account/developer/oidc/clients")
    persistent_body = html_response(persistent_index_conn, 200)
    assert persistent_body =~ OAuth.App.client_secret_fingerprint(app)
    refute persistent_body =~ app.client_secret
    refute persistent_body =~ revealed_secret

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
    edit_body = html_response(edit_conn, 200)
    assert edit_body =~ "Edit OAuth Client"
    assert edit_body =~ OAuth.App.client_secret_fingerprint(app)
    refute edit_body =~ app.client_secret

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
    rotated_secret = Phoenix.Flash.get(rotate_conn.assigns.flash, :client_secret)
    assert is_binary(rotated_secret)

    rotated_app = OAuth.get_user_app(user, app.id)
    assert rotated_app.client_secret != old_secret
    refute rotated_secret == rotated_app.client_secret

    rotated_index_conn = get(rotate_conn, ~p"/account/developer/oidc/clients")
    rotated_body = html_response(rotated_index_conn, 200)
    assert rotated_body =~ rotated_secret
    assert rotated_body =~ OAuth.App.client_secret_fingerprint(rotated_app)
    refute rotated_body =~ rotated_app.client_secret
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
    |> Plug.Conn.put_session(UserAuth.recent_auth_session_key(), System.system_time(:second))
  end
end
