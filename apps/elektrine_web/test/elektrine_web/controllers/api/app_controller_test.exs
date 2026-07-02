defmodule ElektrineWeb.API.AppControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Developer
  alias Elektrine.OAuth

  import Elektrine.AccountsFixtures

  describe "index/2" do
    test "lists OAuth apps owned by the current user without exposing secrets", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, app} =
        OAuth.create_app(%{
          client_name: "Owned Client",
          redirect_uris: "https://client.example/callback",
          scopes: ["read", "write"],
          user_id: user.id,
          website: "https://client.example"
        })

      {:ok, _other_app} =
        OAuth.create_app(%{
          client_name: "Other Client",
          redirect_uris: "https://other.example/callback",
          scopes: ["read"],
          user_id: other_user.id,
          website: "https://other.example"
        })

      {:ok, token} =
        Developer.create_api_token(user.id, %{
          name: "Account reader",
          scopes: ["read:account"]
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.token}")
        |> get("/api/v1/apps")

      assert [
               %{
                 "id" => id,
                 "name" => "Owned Client",
                 "website" => "https://client.example",
                 "redirect_uri" => "https://client.example/callback",
                 "client_id" => client_id,
                 "client_secret" => nil,
                 "client_secret_fingerprint" => "sha256:" <> _,
                 "scopes" => ["read", "write"],
                 "vapid_key" => nil
               }
             ] = json_response(conn, 200)

      assert id == to_string(app.id)
      assert client_id == app.client_id
    end

    test "lists OAuth apps on the compatibility path", %{conn: conn} do
      user = user_fixture()

      {:ok, _app} =
        OAuth.create_app(%{
          client_name: "Compat Client",
          redirect_uris: "https://client.example/callback",
          scopes: ["read"],
          user_id: user.id,
          website: "https://client.example"
        })

      {:ok, token} =
        Developer.create_api_token(user.id, %{
          name: "Account reader",
          scopes: ["read:account"]
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.token}")
        |> get("/api/v1/pleroma/apps")

      assert [%{"name" => "Compat Client"}] = json_response(conn, 200)
    end
  end

  describe "create/2" do
    test "registers an OAuth app for API clients", %{conn: conn} do
      conn =
        post(conn, "/api/v1/apps", %{
          "client_name" => "Desktop Client",
          "redirect_uris" => "https://client.example/callback",
          "scopes" => "read write follow",
          "website" => "https://client.example"
        })

      assert %{
               "id" => id,
               "name" => "Desktop Client",
               "website" => "https://client.example",
               "redirect_uri" => "https://client.example/callback",
               "client_id" => client_id,
               "client_secret" => client_secret,
               "vapid_key" => nil
             } = json_response(conn, 201)

      assert is_binary(id)
      assert is_binary(client_id)
      assert is_binary(client_secret)
      assert OAuth.get_app_by_credentials(client_id, client_secret)
    end

    test "rejects invalid redirect URIs", %{conn: conn} do
      conn =
        post(conn, "/api/v1/apps", %{
          "client_name" => "Bad Client",
          "redirect_uris" => "javascript:alert(1)"
        })

      assert %{
               "error" => "invalid_client_metadata",
               "details" => %{"redirect_uris" => ["contains invalid URI"]}
             } = json_response(conn, 422)
    end
  end

  describe "verify_credentials/2" do
    test "verifies app credentials from bearer OAuth token", %{conn: conn} do
      {:ok, app} =
        OAuth.create_app(%{
          client_name: "Token Client",
          redirect_uris: "https://client.example/callback",
          scopes: ["read"],
          website: "https://client.example"
        })

      assert {:ok, token} = OAuth.create_token(app, nil)

      conn =
        conn
        |> put_req_header(
          "authorization",
          "Bearer #{Elektrine.OAuth.Token.access_token_value(token)}"
        )
        |> get("/api/v1/apps/verify_credentials")

      assert %{
               "name" => "Token Client",
               "website" => "https://client.example",
               "vapid_key" => nil
             } = json_response(conn, 200)

      refute Map.has_key?(json_response(conn, 200), "client_secret")
    end

    test "verifies app credentials from client id and secret", %{conn: conn} do
      conn =
        post(conn, "/api/v1/apps", %{
          "client_name" => "Secret Client",
          "redirect_uris" => "https://client.example/callback",
          "website" => "https://client.example"
        })

      %{"client_id" => client_id, "client_secret" => client_secret} = json_response(conn, 201)

      conn =
        build_conn()
        |> get("/api/v1/apps/verify_credentials", %{
          "client_id" => client_id,
          "client_secret" => client_secret
        })

      assert %{
               "name" => "Secret Client",
               "website" => "https://client.example",
               "vapid_key" => nil
             } = json_response(conn, 200)
    end

    test "rejects invalid app credentials", %{conn: conn} do
      conn =
        get(conn, "/api/v1/apps/verify_credentials", %{
          "client_id" => "missing",
          "client_secret" => "bad"
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end
  end
end
