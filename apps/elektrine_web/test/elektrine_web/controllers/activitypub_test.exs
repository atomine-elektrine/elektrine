defmodule ElektrineWeb.ActivityPubControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.System, as: SystemSettings

  describe "GET /.well-known/webfinger" do
    test "returns webfinger for valid user", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "webfingertest"})
      domain = Elektrine.ActivityPub.instance_domain()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:#{user.username}@#{domain}"})

      response = json_response(conn, 200)
      assert response["subject"] =~ user.username
      assert is_list(response["links"])
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      domain = Elektrine.ActivityPub.instance_domain()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:nonexistent@#{domain}"})

      assert conn.status == 404
    end

    test "returns 400 without resource parameter", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger")

      assert conn.status == 400
    end
  end

  describe "GET /.well-known/nodeinfo" do
    test "returns nodeinfo links", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/nodeinfo")

      response = json_response(conn, 200)
      assert is_list(response["links"])
      assert Enum.any?(response["links"], &(&1["rel"] =~ "nodeinfo"))
    end
  end

  describe "GET /nodeinfo/2.0" do
    test "returns nodeinfo 2.0", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/nodeinfo/2.0")

      response = json_response(conn, 200)
      assert response["version"] == "2.0"
      assert response["software"]["name"]
      assert is_map(response["usage"])
    end
  end

  describe "GET /nodeinfo/2.1" do
    test "returns nodeinfo 2.1", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/nodeinfo/2.1")

      response = json_response(conn, 200)
      assert response["version"] == "2.1"
      assert response["software"]["name"]
    end

    test "openRegistrations reflects invite-only mode", %{conn: conn} do
      previous_value = SystemSettings.invite_codes_enabled?()
      on_exit(fn -> SystemSettings.set_invite_codes_enabled(previous_value) end)

      {:ok, _} = SystemSettings.set_invite_codes_enabled(false)

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/nodeinfo/2.1")

      response = json_response(conn, 200)
      assert response["openRegistrations"] == true

      {:ok, _} = SystemSettings.set_invite_codes_enabled(true)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/nodeinfo/2.1")

      response = json_response(conn, 200)
      assert response["openRegistrations"] == false
    end
  end

  describe "GET /users/:username (actor)" do
    setup do
      user = AccountsFixtures.user_fixture(%{username: "actortest"})
      %{user: user}
    end

    test "returns ActivityPub actor", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      response = json_response(conn, 200)
      assert response["type"] == "Person"
      assert response["preferredUsername"] == user.username
      assert response["inbox"]
      assert response["outbox"]
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/nonexistent")

      assert conn.status == 404
    end
  end

  describe "GET /users/:username/outbox" do
    setup do
      user = AccountsFixtures.user_fixture(%{username: "outboxtest"})
      %{user: user}
    end

    test "returns outbox collection", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/outbox")

      response = json_response(conn, 200)
      assert response["type"] in ["OrderedCollection", "OrderedCollectionPage"]
    end

    test "returns totalItems count", %{conn: conn, user: user} do
      for n <- 1..2 do
        {:ok, _activity} =
          ActivityPub.create_activity(%{
            activity_id: "https://example.test/activities/#{Ecto.UUID.generate()}-#{n}",
            activity_type: "Create",
            actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
            data: %{"id" => "https://example.test/objects/#{n}", "type" => "Create"},
            local: true,
            internal_user_id: user.id
          })
      end

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/outbox")

      response = json_response(conn, 200)
      assert response["type"] == "OrderedCollection"
      assert response["totalItems"] == 2

      assert response["first"] ==
               "#{ActivityPub.instance_url()}/users/#{user.username}/outbox?page=1"
    end

    test "supports outbox pagination links", %{conn: conn, user: user} do
      for n <- 1..25 do
        {:ok, _activity} =
          ActivityPub.create_activity(%{
            activity_id: "https://example.test/activities/#{Ecto.UUID.generate()}-page-#{n}",
            activity_type: "Create",
            actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
            data: %{"id" => "https://example.test/objects/page/#{n}", "type" => "Create"},
            local: true,
            internal_user_id: user.id
          })
      end

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/outbox", %{page: "2"})

      response = json_response(conn, 200)
      assert response["type"] == "OrderedCollectionPage"

      assert response["id"] ==
               "#{ActivityPub.instance_url()}/users/#{user.username}/outbox?page=2"

      assert response["prev"] ==
               "#{ActivityPub.instance_url()}/users/#{user.username}/outbox?page=1"

      refute Map.has_key?(response, "next")
    end
  end

  describe "GET /users/:username/followers" do
    setup do
      user = AccountsFixtures.user_fixture(%{username: "followerstest"})
      %{user: user}
    end

    test "returns followers collection", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/followers")

      response = json_response(conn, 200)
      assert response["type"] in ["OrderedCollection", "OrderedCollectionPage"]
    end
  end

  describe "GET /users/:username/following" do
    setup do
      user = AccountsFixtures.user_fixture(%{username: "followingtest"})
      %{user: user}
    end

    test "returns following collection", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/following")

      response = json_response(conn, 200)
      assert response["type"] in ["OrderedCollection", "OrderedCollectionPage"]
    end
  end

  describe "POST /users/:username/inbox" do
    setup do
      user = AccountsFixtures.user_fixture(%{username: "inboxtest"})
      %{user: user}
    end

    test "rejects unsigned requests", %{conn: conn, user: user} do
      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Follow",
        "actor" => "https://remote.example/users/someone",
        "object" => "https://localhost/users/#{user.username}"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/users/#{user.username}/inbox", activity)

      # Should reject unsigned request (401 or 403)
      assert conn.status in [400, 401, 403]
    end
  end

  describe "POST /inbox (shared inbox)" do
    test "rejects unsigned requests", %{conn: conn} do
      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "actor" => "https://remote.example/users/someone",
        "object" => %{
          "type" => "Note",
          "content" => "Hello"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/inbox", activity)

      # Should reject unsigned request
      assert conn.status in [400, 401, 403]
    end
  end

  describe "GET /tags/:name" do
    test "returns hashtag collection", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/test")

      response = json_response(conn, 200)
      assert response["type"] in ["OrderedCollection", "OrderedCollectionPage", "Collection"]
    end
  end
end
