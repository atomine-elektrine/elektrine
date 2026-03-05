defmodule ElektrineWeb.API.ExtV1ControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer

  describe "PAT auth + versioned external API" do
    test "returns standardized missing token error", %{conn: conn} do
      conn = get(conn, "/api/ext/v1/search", %{"q" => "hello"})

      assert %{"error" => error, "meta" => _meta} = json_response(conn, 401)
      assert error["code"] == "missing_token"
      assert error["message"] == "API token required"
    end

    test "search endpoint returns data and pagination meta", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:account"])

      conn = get(conn, "/api/ext/v1/search", %{"q" => "hello", "limit" => "5"})

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert data["query"] == "hello"
      assert is_list(data["results"])
      assert meta["pagination"]["limit"] == 5
    end

    test "export endpoints require export scope", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:account"])

      conn = get(conn, "/api/ext/v1/exports")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "insufficient_scope"
    end

    test "webhook endpoints work with webhook scope", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["webhook"])

      create_payload = %{
        "name" => "API Hook",
        "url" => "https://example.com/webhook",
        "events" => ["post.created"]
      }

      created_conn = post(conn, "/api/ext/v1/webhooks", create_payload)

      assert %{"data" => created_data} = json_response(created_conn, 201)
      assert %{"id" => webhook_id, "name" => "API Hook"} = created_data["webhook"]
      assert is_binary(created_data["secret"])

      show_conn = get(conn, "/api/ext/v1/webhooks/#{webhook_id}")
      assert %{"data" => show_data} = json_response(show_conn, 200)
      assert show_data["webhook"]["id"] == webhook_id

      delete_conn = delete(conn, "/api/ext/v1/webhooks/#{webhook_id}")
      assert %{"data" => %{"message" => "Webhook deleted"}} = json_response(delete_conn, 200)
    end
  end

  defp with_pat(conn, user_id, scopes) do
    {:ok, token} =
      Developer.create_api_token(user_id, %{
        name: "test-token-#{System.unique_integer([:positive])}",
        scopes: scopes
      })

    put_req_header(conn, "authorization", "Bearer #{token.token}")
  end
end
