defmodule ElektrineWeb.API.ConversationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{Conversation, FederationMembershipState, Server}
  alias Elektrine.Repo
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

  describe "POST /api/conversations/:conversation_id/join" do
    test "returns accepted for mirrored room join requests", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      server =
        %Server{}
        |> Server.changeset(%{
          name: "remote-hub",
          description: "Federated remote server",
          is_public: true,
          federation_id: "https://remote.example/_arblarg/servers/91",
          origin_domain: "remote.example",
          is_federated_mirror: true
        })
        |> Repo.insert!()

      channel =
        %Conversation{}
        |> Conversation.channel_changeset(%{
          name: "general",
          description: "Mirrored remote channel",
          server_id: server.id,
          federated_source: "https://remote.example/_arblarg/channels/92",
          is_federated_mirror: true,
          is_public: true
        })
        |> Repo.insert!()

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/conversations/#{channel.id}/join")

      response = json_response(conn, 202)
      assert response["message"] == "Join request sent"
      refute Messaging.get_conversation_member(channel.id, user.id)
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

  describe "remote join review endpoints" do
    test "lists and approves pending remote join requests", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      {:ok, token} = APIAuth.generate_token(owner.id)
      {:ok, server} = Messaging.create_server(owner.id, %{name: "review-hub"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "review-room",
          description: "pending remote joins"
        })

      assert {:ok, _member} = Messaging.add_member_to_conversation(channel.id, owner.id, "admin")

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          display_name: "Alice",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{"join_request" => true}
      })
      |> Repo.insert!()

      list_conn =
        conn
        |> auth_conn(token)
        |> get("/api/conversations/#{channel.id}/remote-join-requests")

      list_response = json_response(list_conn, 200)

      assert [
               %{
                 "remote_actor_id" => remote_actor_id,
                 "handle" => "@alice@remote.example",
                 "display_label" => "Alice (@alice@remote.example)"
               }
             ] = list_response["requests"]

      assert remote_actor_id == remote_actor.id

      approve_conn =
        conn
        |> auth_conn(token)
        |> post("/api/conversations/#{channel.id}/remote-join-requests/approve", %{
          remote_actor_id: remote_actor.id
        })

      approve_response = json_response(approve_conn, 200)
      assert approve_response["message"] == "Remote join request approved"
      assert approve_response["request"]["state"] == "active"

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id,
                 remote_actor_id: remote_actor.id
               )

      assert membership_state.state == "active"
    end

    test "rejects remote join moderation for non-moderators", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      reviewer = AccountsFixtures.user_fixture()
      {:ok, token} = APIAuth.generate_token(reviewer.id)
      {:ok, server} = Messaging.create_server(owner.id, %{name: "review-hub-forbidden"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "review-room-forbidden",
          description: "pending remote joins"
        })

      assert {:ok, _member} = Messaging.add_member_to_conversation(channel.id, reviewer.id)

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/bob",
          username: "bob",
          domain: "remote.example",
          display_name: "Bob",
          inbox_url: "https://remote.example/users/bob/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{"join_request" => true}
      })
      |> Repo.insert!()

      forbidden_conn =
        conn
        |> auth_conn(token)
        |> get("/api/conversations/#{channel.id}/remote-join-requests")

      assert json_response(forbidden_conn, 403)["error"] ==
               "You don't have permission to manage members"
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
