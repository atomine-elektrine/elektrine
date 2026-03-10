defmodule ElektrineWeb.ActivityPubControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Domains
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures
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

    test "returns webfinger for community acct handle", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "community#{unique}"})

      domain = Elektrine.ActivityPub.instance_domain()
      resource = "acct:!#{community.name}@#{domain}"

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: resource})

      response = json_response(conn, 200)
      assert response["subject"] == resource

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "self" and
                 link["href"] == ActivityPub.community_actor_uri(community.name)
             end)
    end

    test "canonicalizes community webfinger responses to slugged actor ids", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "webfingercommunityowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Machine Learning #{unique}"})

      domain = Elektrine.ActivityPub.instance_domain()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:!#{community.name}@#{domain}"})

      response = json_response(conn, 200)
      slug = ActivityPub.community_slug(community.name)

      assert response["subject"] == "acct:!#{slug}@#{domain}"

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "self" and
                 link["href"] == ActivityPub.community_actor_uri(community.name)
             end)
    end

    test "supports legacy !community@domain webfinger resources", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communitylegacyowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "legacycommunity#{unique}"})

      domain = Elektrine.ActivityPub.instance_domain()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "!#{community.name}@#{domain}"})

      response = json_response(conn, 200)
      assert response["subject"] == "acct:!#{community.name}@#{domain}"
    end

    test "resolves webfinger on configured non-canonical local domains", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "legacydomainuser"})

      instance_domain = ActivityPub.instance_domain()
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains)

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)
      end)

      Application.put_env(:elektrine, :profile_base_domains, [instance_domain, "z.org"])

      requested_domain =
        Domains.activitypub_domains()
        |> Enum.find(&(&1 != instance_domain))

      assert is_binary(requested_domain)

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:#{user.username}@#{requested_domain}"})

      response = json_response(conn, 200)
      assert response["subject"] == "acct:#{user.username}@#{requested_domain}"
      assert Enum.any?(response["links"], &(&1["rel"] == "self"))
    end

    test "returns legacy-domain self link when migration domain is configured", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "legacywebfingeruser"})
      instance_domain = ActivityPub.instance_domain()
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains)
      previous_move_domain = System.get_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)

        case previous_move_domain do
          nil -> System.delete_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")
          value -> System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", value)
        end
      end)

      Application.put_env(:elektrine, :profile_base_domains, [instance_domain, "z.org"])
      System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", "z.org")

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:#{user.username}@z.org"})

      response = json_response(conn, 200)
      assert response["subject"] == "acct:#{user.username}@z.org"

      legacy_actor_url = "#{ActivityPub.instance_url_for_domain("z.org")}/users/#{user.username}"

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "self" and link["href"] == legacy_actor_url
             end)
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

    test "returns legacy actor with movedTo on migration domain host", %{conn: conn, user: user} do
      previous_move_domain = System.get_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")

      on_exit(fn ->
        case previous_move_domain do
          nil -> System.delete_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")
          value -> System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", value)
        end
      end)

      System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", "z.org")

      conn =
        %{conn | host: "z.org"}
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      response = json_response(conn, 200)

      assert response["id"] ==
               "#{ActivityPub.instance_url_for_domain("z.org")}/users/#{user.username}"

      assert response["movedTo"] == "#{ActivityPub.instance_url()}/users/#{user.username}"
    end

    test "returns canonical actor with alsoKnownAs when migration domain is configured", %{
      conn: conn,
      user: user
    } do
      previous_move_domain = System.get_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")

      on_exit(fn ->
        case previous_move_domain do
          nil -> System.delete_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")
          value -> System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", value)
        end
      end)

      System.put_env("ACTIVITYPUB_MOVE_FROM_DOMAIN", "z.org")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      response = json_response(conn, 200)
      assert response["id"] == "#{ActivityPub.instance_url()}/users/#{user.username}"
      assert is_list(response["alsoKnownAs"])

      assert "#{ActivityPub.instance_url_for_domain("z.org")}/users/#{user.username}" in response[
               "alsoKnownAs"
             ]
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

  describe "GET /c/:name" do
    test "resolves slugged community actor paths", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityactorowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Machine Learning #{unique}"})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}")

      response = json_response(conn, 200)

      assert response["id"] == ActivityPub.community_actor_uri(community.name)
      assert response["preferredUsername"] == ActivityPub.community_slug(community.name)
      assert response["name"] == community.name
    end
  end

  describe "GET /c/:name/posts/:id" do
    setup do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityposter#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "communityposts#{unique}"})

      post = SocialFixtures.discussion_post_fixture(%{user: owner, community: community})
      %{community: community, post: post}
    end

    test "returns community post object", %{conn: conn, community: community, post: post} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{post.id}")

      response = json_response(conn, 200)
      community_url = ActivityPub.community_actor_uri(community.name)
      post_id = ActivityPub.community_post_uri(community.name, post.id)

      assert response["type"] == "Page"
      assert response["id"] == post_id
      assert response["audience"] == community_url
    end

    test "returns create activity wrapper for community post", %{
      conn: conn,
      community: community,
      post: post
    } do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{post.id}/activity")

      response = json_response(conn, 200)
      community_url = ActivityPub.community_actor_uri(community.name)
      post_id = ActivityPub.community_post_uri(community.name, post.id)

      assert response["type"] == "Create"
      assert response["id"] == "#{post_id}/activity"
      assert response["actor"] == community_url
      assert response["object"]["id"] == post_id
    end

    test "includes inReplyTo for community replies", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityreplyowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Machine Learning #{unique}"})

      parent_post = SocialFixtures.discussion_post_fixture(%{user: owner, community: community})
      reply = community_reply_fixture(owner, community, parent_post)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{reply.id}")

      response = json_response(conn, 200)

      assert response["type"] == "Note"

      assert response["inReplyTo"] ==
               ActivityPub.community_post_uri(community.name, parent_post.id)
    end
  end

  describe "POST /c/:name/inbox" do
    setup do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityinboxowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Machine Learning #{unique}"})

      {:ok, group_actor} = ActivityPub.get_or_create_community_actor(community.id)
      remote_actor = remote_actor_fixture("communityfollower")

      %{community: community, group_actor: group_actor, remote_actor: remote_actor}
    end

    test "persists remote follows for local communities", %{
      conn: conn,
      community: community,
      group_actor: group_actor,
      remote_actor: remote_actor
    } do
      follow_id = "https://remote.example/activities/#{System.unique_integer([:positive])}"

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => follow_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => group_actor.uri
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", activity)

      assert json_response(conn, 202) == %{}

      assert follow = ActivityPub.get_group_follow(remote_actor.id, group_actor.id)
      assert follow.activitypub_id == follow_id
    end

    test "removes persisted community follows on Undo", %{
      conn: conn,
      community: community,
      group_actor: group_actor,
      remote_actor: remote_actor
    } do
      follow_id = "https://remote.example/activities/#{System.unique_integer([:positive])}"

      follow_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => follow_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => group_actor.uri
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", follow_activity)

      assert json_response(conn, 202) == %{}
      assert ActivityPub.get_group_follow(remote_actor.id, group_actor.id)

      undo_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Undo",
        "actor" => remote_actor.uri,
        "object" => follow_activity
      }

      conn =
        build_conn()
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", undo_activity)

      assert json_response(conn, 202) == %{}
      assert ActivityPub.get_group_follow(remote_actor.id, group_actor.id) == nil
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

  defp community_reply_fixture(author, community, parent_post) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: community.id,
      sender_id: author.id,
      content: "Reply #{System.unique_integer([:positive])}",
      message_type: "text",
      visibility: "public",
      post_type: "comment",
      reply_to_id: parent_post.id
    })
    |> Repo.insert!()
    |> Repo.preload([:sender, :conversation])
  end

  defp remote_actor_fixture(label) do
    unique = System.unique_integer([:positive])
    username = "#{label}#{unique}"
    uri = "https://remote.example/users/#{username}"

    %Actor{}
    |> Actor.changeset(%{
      uri: uri,
      username: username,
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{username}/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
