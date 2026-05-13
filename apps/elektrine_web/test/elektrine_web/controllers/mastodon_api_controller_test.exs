defmodule ElektrineWeb.MastodonAPIControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.OAuth
  alias Elektrine.OAuth.App

  describe "app credentials" do
    test "app-only tokens can verify app credentials", %{conn: conn} do
      {:ok, app} =
        OAuth.create_app(%{
          client_name: "Mobile Client",
          redirect_uris: "mastodon://oauth",
          scopes: ["read"]
        })

      token_conn =
        conn
        |> put_req_header("accept", "application/json")
        |> post(~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => app.client_id,
          "client_secret" => App.client_secret_value(app),
          "scope" => "read"
        })

      assert %{"access_token" => access_token, "token_type" => "Bearer"} =
               json_response(token_conn, 200)

      verify_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get(~p"/api/v1/apps/verify_credentials")

      assert %{"id" => app_id, "name" => "Mobile Client"} = json_response(verify_conn, 200)
      assert app_id == to_string(app.id)
    end
  end

  describe "account route ordering" do
    test "verify_credentials is not shadowed by the account id route", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/accounts/verify_credentials")

      assert %{"error" => "The access token is invalid"} = json_response(conn, 401)
    end

    test "relationships is not shadowed by the account id route", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/accounts/relationships")

      assert %{"error" => "The access token is invalid"} = json_response(conn, 401)
    end
  end
end
