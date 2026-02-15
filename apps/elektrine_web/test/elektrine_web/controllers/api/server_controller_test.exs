defmodule ElektrineWeb.API.ServerControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
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

  describe "POST /api/servers" do
    test "creates a server with default channel", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/servers", %{
          name: "builders",
          description: "Builder chat",
          is_public: true
        })

      response = json_response(conn, 201)
      assert response["server"]["name"] == "builders"
      assert is_list(response["channels"])
      assert Enum.any?(response["channels"], &(&1["name"] == "general"))
    end
  end

  describe "GET /api/servers" do
    test "lists servers for current user", %{conn: conn, token: token, user: user} do
      {:ok, _server} = Messaging.create_server(user.id, %{name: "alpha"})

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/servers")

      response = json_response(conn, 200)
      assert is_list(response["servers"])
      assert Enum.any?(response["servers"], &(&1["name"] == "alpha"))
    end
  end

  describe "POST /api/servers/:server_id/join" do
    test "joins a public server", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, joiner_token} = APIAuth.generate_token(joiner.id)

      {:ok, server} = Messaging.create_server(owner.id, %{name: "public-space", is_public: true})

      conn =
        conn
        |> auth_conn(joiner_token)
        |> post("/api/servers/#{server.id}/join")

      response = json_response(conn, 200)
      assert response["message"] == "Joined server"
      assert response["server"]["id"] == server.id
    end
  end

  describe "POST /api/servers/:server_id/channels" do
    test "prevents regular members from creating channels", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      member = AccountsFixtures.user_fixture()
      {:ok, member_token} = APIAuth.generate_token(member.id)

      {:ok, server} = Messaging.create_server(owner.id, %{name: "team", is_public: true})
      {:ok, _} = Messaging.join_server(server.id, member.id)

      conn =
        conn
        |> auth_conn(member_token)
        |> post("/api/servers/#{server.id}/channels", %{name: "private-mod"})

      response = json_response(conn, 403)
      assert response["error"] =~ "permission"
    end
  end
end
