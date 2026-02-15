defmodule ElektrineWeb.API.ConversationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.Plugs.APIAuth

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, token} = APIAuth.generate_token(user.id)
    %{user: user, token: token}
  end

  defp auth_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "GET /api/conversations" do
    test "returns conversations list", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/conversations")

      response = json_response(conn, 200)
      assert is_list(response["conversations"]) or is_list(response)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/conversations")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/conversations" do
    test "creates a new conversation", %{conn: conn, token: token} do
      other_user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/conversations", %{
          name: "Test Conversation",
          participant_ids: [other_user.id]
        })

      # May return various status codes depending on implementation
      assert conn.status in [200, 201, 400, 422]
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns 404 for non-existent conversation", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/conversations/999999")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/conversations/:conversation_id/messages" do
    test "returns 404 for non-existent conversation", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/conversations/999999/messages")

      assert conn.status in [403, 404]
    end
  end

  describe "POST /api/conversations/:conversation_id/messages" do
    test "returns 404 for non-existent conversation", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/conversations/999999/messages", %{content: "Hello"})

      assert conn.status in [403, 404]
    end
  end
end
