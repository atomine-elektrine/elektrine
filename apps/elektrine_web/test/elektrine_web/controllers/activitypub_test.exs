defmodule ElektrineWeb.ActivityPubControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Domains
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.SocialFixtures
  alias Elektrine.System, as: SystemSettings

  describe "GET /relay" do
    test "does not advertise unsupported collection endpoints", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/relay")

      response = json_response(conn, 200)

      assert response["id"] == "#{ActivityPub.instance_url()}/relay"
      assert response["inbox"] == "#{ActivityPub.instance_url()}/relay/inbox"
      refute Map.has_key?(response, "outbox")
      refute Map.has_key?(response, "followers")
      refute Map.has_key?(response, "following")
    end
  end

  describe "GET /.well-known/webfinger" do
    test "returns webfinger for valid user", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "webfingertest"})
      domain = Elektrine.ActivityPub.instance_domain()
      base_url = ActivityPub.instance_url()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:#{user.username}@#{domain}"})

      response = json_response(conn, 200)
      assert response["subject"] =~ user.username
      assert is_list(response["links"])

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "http://ostatus.org/schema/1.0/subscribe" and
                 link["template"] == "#{base_url}/authorize_interaction?uri={uri}"
             end)
    end

    test "returns canonical handle self link for username aliases", %{conn: conn} do
      user =
        AccountsFixtures.user_fixture(%{username: "webfingeraliasuser"})
        |> set_handle!("ap_handle")

      domain = Elektrine.ActivityPub.instance_domain()

      conn =
        conn
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{resource: "acct:#{user.username}@#{domain}"})

      response = json_response(conn, 200)

      assert response["subject"] == "acct:#{user.username}@#{domain}"

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "self" and link["href"] == ActivityPub.actor_uri(user)
             end)
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

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "http://ostatus.org/schema/1.0/subscribe" and
                 link["template"] ==
                   "#{ActivityPub.instance_url()}/authorize_interaction?uri={uri}"
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

    test "returns alias webfinger for a verified custom profile domain", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "customdomainaliasuser"})
      custom_domain = verified_profile_custom_domain_fixture(user, "customdomainalias.test")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{
          resource: "acct:#{user.username}@#{custom_domain.domain}"
        })

      response = json_response(conn, 200)

      assert response["subject"] == "acct:#{user.username}@#{custom_domain.domain}"

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "self" and
                 link["href"] == "#{ActivityPub.instance_url()}/users/#{user.username}"
             end)

      assert Enum.any?(response["links"], fn link ->
               link["rel"] == "http://webfinger.net/rel/profile-page" and
                 link["href"] == "https://#{custom_domain.domain}"
             end)
    end

    test "does not resolve other users on someone else's custom profile domain", %{conn: conn} do
      owner = AccountsFixtures.user_fixture(%{username: "customdomainowner"})
      other_user = AccountsFixtures.user_fixture(%{username: "customdomainother"})
      custom_domain = verified_profile_custom_domain_fixture(owner, "customdomainowner.test")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger", %{
          resource: "acct:#{other_user.username}@#{custom_domain.domain}"
        })

      assert conn.status == 404
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

  describe "GET /.well-known/host-meta" do
    test "uses the custom profile domain host for verified alias domains", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "customdomainhostmeta"})
      custom_domain = verified_profile_custom_domain_fixture(user, "customhostmeta.test")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> get("/.well-known/host-meta")

      body = response(conn, 200)

      assert body =~
               "template=\"https://#{custom_domain.domain}/.well-known/webfinger?resource={uri}\""
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
      assert response["software"]["name"] == "elektrine"
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
      assert response["software"]["name"] == "elektrine"
      assert response["metadata"]["nodeName"] == "Elektrine"
      assert response["metadata"]["nodeDescription"] == "An Elektrine instance"
    end

    test "uses configured nodeinfo branding", %{conn: conn} do
      previous_software_name = Application.get_env(:elektrine, :nodeinfo_software_name)
      previous_instance_name = Application.get_env(:elektrine, :instance_name)
      previous_instance_description = Application.get_env(:elektrine, :instance_description)

      on_exit(fn ->
        restore_env(:nodeinfo_software_name, previous_software_name)
        restore_env(:instance_name, previous_instance_name)
        restore_env(:instance_description, previous_instance_description)
      end)

      Application.put_env(:elektrine, :nodeinfo_software_name, "Elektrine")
      Application.put_env(:elektrine, :instance_name, "My Elektrine Node")
      Application.put_env(:elektrine, :instance_description, "Custom ActivityPub description")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/nodeinfo/2.1")

      response = json_response(conn, 200)
      assert response["software"]["name"] == "elektrine"
      assert response["metadata"]["nodeName"] == "My Elektrine Node"
      assert response["metadata"]["nodeDescription"] == "Custom ActivityPub description"
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

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)

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

    test "serves handle paths as canonical actors and username paths as moved aliases", %{conn: conn} do
      user =
        AccountsFixtures.user_fixture(%{username: "actoraliasuser"})
        |> set_handle!("actor_handle")

      canonical_conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.handle}")

      canonical_response = json_response(canonical_conn, 200)
      canonical_actor_uri = ActivityPub.actor_uri(user)
      username_alias_uri = ActivityPub.actor_uri_by_username(user)

      assert canonical_response["id"] == canonical_actor_uri
      assert canonical_response["preferredUsername"] == user.handle
      assert username_alias_uri in (canonical_response["alsoKnownAs"] || [])

      alias_conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      alias_response = json_response(alias_conn, 200)

      assert alias_response["id"] == username_alias_uri
      assert alias_response["preferredUsername"] == user.handle
      assert alias_response["movedTo"] == canonical_actor_uri
    end

    test "exports active profile links as actor attachments", %{conn: conn, user: user} do
      {:ok, profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Actor Test",
          description: "ActivityPub profile"
        })

      {:ok, _website_link} =
        Profiles.create_profile_link(profile.id, %{
          title: "Website",
          url: "https://example.com",
          position: 2,
          is_active: true
        })

      {:ok, _email_link} =
        Profiles.create_profile_link(profile.id, %{
          title: "Email",
          url: "mailto:test@example.com",
          position: 1,
          is_active: true
        })

      {:ok, _inactive_link} =
        Profiles.create_profile_link(profile.id, %{
          title: "Hidden",
          url: "https://hidden.example.com",
          position: 0,
          is_active: false
        })

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      response = json_response(conn, 200)
      attachments = response["attachment"]

      assert is_list(attachments)
      assert Enum.map(attachments, & &1["name"]) == ["Email", "Website"]
      refute Enum.any?(attachments, &(&1["name"] == "Hidden"))

      email_field = Enum.find(attachments, &(&1["name"] == "Email"))
      assert email_field["type"] == "PropertyValue"
      assert email_field["value"] =~ ~s(href="mailto:test@example.com")
      assert email_field["value"] =~ ~s(rel="nofollow noopener noreferrer")
      refute email_field["value"] =~ ~s(target="_blank")

      website_field = Enum.find(attachments, &(&1["name"] == "Website"))
      assert website_field["type"] == "PropertyValue"
      assert website_field["value"] =~ ~s(href="https://example.com")
      assert website_field["value"] =~ ~s(rel="me nofollow noopener noreferrer")
      assert website_field["value"] =~ ~s(target="_blank")
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

    test "allows unsigned actor fetches when authorized fetch mode is enabled", %{
      conn: conn,
      user: user
    } do
      previous_activitypub_config = Application.get_env(:elektrine, :activitypub, [])

      on_exit(fn ->
        Application.put_env(:elektrine, :activitypub, previous_activitypub_config)
      end)

      Application.put_env(
        :elektrine,
        :activitypub,
        Keyword.put(previous_activitypub_config, :authorized_fetch_mode, true)
      )

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}")

      response = json_response(conn, 200)
      assert response["id"] == "#{ActivityPub.instance_url()}/users/#{user.username}"
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
            data: %{
              "id" => "https://example.test/objects/#{n}",
              "type" => "Create",
              "to" => ["https://www.w3.org/ns/activitystreams#Public"],
              "cc" => []
            },
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
            data: %{
              "id" => "https://example.test/objects/page/#{n}",
              "type" => "Create",
              "to" => ["https://www.w3.org/ns/activitystreams#Public"],
              "cc" => []
            },
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

    test "excludes non-public activities from the public outbox", %{conn: conn, user: user} do
      public_activity_id = "https://example.test/activities/#{Ecto.UUID.generate()}-public"
      followers_activity_id = "https://example.test/activities/#{Ecto.UUID.generate()}-followers"

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: public_activity_id,
          activity_type: "Create",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          data: %{
            "id" => public_activity_id,
            "type" => "Create",
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "cc" => ["#{ActivityPub.instance_url()}/users/#{user.username}/followers"]
          },
          local: true,
          internal_user_id: user.id
        })

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: followers_activity_id,
          activity_type: "Create",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          data: %{
            "id" => followers_activity_id,
            "type" => "Create",
            "to" => ["#{ActivityPub.instance_url()}/users/#{user.username}/followers"],
            "cc" => []
          },
          local: true,
          internal_user_id: user.id
        })

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/outbox")

      response = json_response(conn, 200)
      assert response["totalItems"] == 1

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/outbox", %{page: "1"})

      page = json_response(conn, 200)
      assert Enum.map(page["orderedItems"], & &1["id"]) == [public_activity_id]
    end
  end

  describe "GET /users/:username/statuses/:id" do
    test "returns public posts", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: user, visibility: "public"})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{post.id}")

      response = json_response(conn, 200)
      assert response["type"] == "Note"
      assert response["content"] =~ post.content
    end

    test "returns 404 for followers-only posts", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: user, visibility: "followers"})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{post.id}")

      assert json_response(conn, 404)["error"] == "Not found"
    end

    test "returns 404 when ActivityPub is disabled for the user", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: user, visibility: "public"})

      user
      |> Ecto.Changeset.change(activitypub_enabled: false)
      |> Repo.update!()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{post.id}")

      assert json_response(conn, 404)["error"] == "Not found"
    end

    test "does not expose community posts through the user status endpoint", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      community = SocialFixtures.community_conversation_fixture(user)

      post =
        SocialFixtures.discussion_post_fixture(%{user: user, community: community})
        |> then(fn message ->
          message
          |> Ecto.Changeset.change(
            activitypub_id: ActivityPub.community_post_uri(community.name, message.id),
            activitypub_url: ActivityPub.community_post_web_url(community.name, message.id)
          )
          |> Repo.update!()
        end)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{post.id}")

      assert json_response(conn, 404)["error"] == "Not found"
    end

    test "serves mirrored community posts when their canonical object id is a user status URI",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      remote_group = remote_group_actor_fixture("statusmirror")

      community =
        SocialFixtures.community_conversation_fixture(user, %{name: "Mirror Status Community"})
        |> Ecto.Changeset.change(
          is_federated_mirror: true,
          remote_group_actor_id: remote_group.id,
          federated_source: remote_group.uri
        )
        |> Repo.update!()

      post = SocialFixtures.discussion_post_fixture(%{user: user, community: community})

      assert :ok = Elektrine.ActivityPub.Outbox.federate_community_post(post, community)

      reloaded_post =
        Messaging.get_message(post.id)
        |> Repo.preload([:sender, :conversation])

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{reloaded_post.id}")

      response = json_response(conn, 200)

      assert response["id"] == reloaded_post.activitypub_id
      assert response["audience"] == remote_group.uri
      assert response["cc"] == [remote_group.uri]
    end

    test "serializes local polls as Question objects", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      post = create_poll_post!(:timeline, user)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/#{user.username}/statuses/#{post.id}")

      response = json_response(conn, 200)

      assert response["type"] == "Question"
      assert response["name"] == "Pick one"
      assert Enum.map(response["oneOf"], & &1["name"]) == ["One", "Two"]
      assert response["content"] =~ "Pick one"
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

    test "allows unsigned community actor fetches when authorized fetch mode is enabled", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityfetchowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Community #{unique}"})

      previous_activitypub_config = Application.get_env(:elektrine, :activitypub, [])

      on_exit(fn ->
        Application.put_env(:elektrine, :activitypub, previous_activitypub_config)
      end)

      Application.put_env(
        :elektrine,
        :activitypub,
        Keyword.put(previous_activitypub_config, :authorized_fetch_mode, true)
      )

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}")

      response = json_response(conn, 200)
      assert response["id"] == ActivityPub.community_actor_uri(community.name)
    end

    test "does not expose mirrored communities as local Group actors", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "mirrorcommunityowner#{unique}"})
      remote_group = remote_group_actor_fixture("groupactor")

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Mirror Actor #{unique}"})
        |> Ecto.Changeset.change(
          is_federated_mirror: true,
          remote_group_actor_id: remote_group.id,
          federated_source: remote_group.uri
        )
        |> Repo.update!()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}")

      assert json_response(conn, 404)["error"] == "Community not found"
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

    test "sanitizes community post content before exposing ActivityPub HTML", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communitysanitizeowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Sanitize Community #{unique}"
        })

      post =
        %Message{}
        |> Message.changeset(%{
          conversation_id: community.id,
          sender_id: owner.id,
          title: "Unsafe HTML",
          content: "<b onclick=\"alert('xss')\">Hello</b>",
          message_type: "text",
          visibility: "public",
          post_type: "discussion"
        })
        |> Repo.insert!()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{post.id}")

      response = json_response(conn, 200)

      assert response["content"] =~ "Hello"
      refute response["content"] =~ "onclick"
    end

    test "does not expose draft community posts or activities", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communitydraftowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Draft Community #{unique}"})

      draft_post =
        SocialFixtures.discussion_post_fixture(%{user: owner, community: community})
        |> Ecto.Changeset.change(is_draft: true)
        |> Repo.update!()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{draft_post.id}")

      assert json_response(conn, 404) == %{"error" => "Not found"}

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{draft_post.id}/activity")

      assert json_response(conn, 404) == %{"error" => "Not found"}
    end

    test "does not expose community posts from ActivityPub-disabled local authors", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communitydisabledowner#{unique}"})

      disabled_user =
        AccountsFixtures.user_fixture(%{username: "communitydisabledauthor#{unique}"})
        |> Ecto.Changeset.change(activitypub_enabled: false)
        |> Repo.update!()

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Disabled Community #{unique}"
        })

      disabled_post =
        SocialFixtures.discussion_post_fixture(%{user: disabled_user, community: community})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{disabled_post.id}")

      assert json_response(conn, 404) == %{"error" => "Not found"}

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get(
          "/c/#{ActivityPub.community_slug(community.name)}/posts/#{disabled_post.id}/activity"
        )

      assert json_response(conn, 404) == %{"error" => "Not found"}
    end

    test "serializes community polls as Question objects", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communitypollowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Poll Community #{unique}"})

      post = create_poll_post!(:community, owner, community)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{post.id}")

      response = json_response(conn, 200)

      assert response["type"] == "Question"
      assert response["id"] == ActivityPub.community_post_uri(community.name, post.id)
      assert response["name"] == post.title
      assert Enum.map(response["oneOf"], & &1["name"]) == ["One", "Two"]

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/posts/#{post.id}/activity")

      activity = json_response(conn, 200)
      assert activity["type"] == "Create"
      assert activity["object"]["type"] == "Question"
    end
  end

  describe "GET /c/:name/outbox" do
    test "normalizes invalid page params instead of raising", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityoutboxowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Outbox Community #{unique}"})

      _post = SocialFixtures.discussion_post_fixture(%{user: owner, community: community})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/outbox", %{page: "foo"})

      response = json_response(conn, 200)

      assert response["type"] == "OrderedCollectionPage"

      assert response["id"] ==
               "#{ActivityPub.community_outbox_uri(community.name)}?page=1"
    end

    test "only includes public non-draft posts from ActivityPub-enabled local authors", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityoutboxfilter#{unique}"})

      disabled_user =
        AccountsFixtures.user_fixture(%{username: "communityoutboxdisabled#{unique}"})
        |> Ecto.Changeset.change(activitypub_enabled: false)
        |> Repo.update!()

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Filtered Outbox #{unique}"})

      public_post = SocialFixtures.discussion_post_fixture(%{user: owner, community: community})

      followers_post =
        SocialFixtures.discussion_post_fixture(%{user: owner, community: community})
        |> Ecto.Changeset.change(visibility: "followers")
        |> Repo.update!()

      draft_post =
        SocialFixtures.discussion_post_fixture(%{user: owner, community: community})
        |> Ecto.Changeset.change(is_draft: true)
        |> Repo.update!()

      disabled_post =
        SocialFixtures.discussion_post_fixture(%{user: disabled_user, community: community})

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/outbox")

      response = json_response(conn, 200)
      assert response["totalItems"] == 1

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/outbox", %{page: "1"})

      page = json_response(conn, 200)

      assert Enum.map(page["orderedItems"], & &1["object"]["id"]) == [
               ActivityPub.community_post_uri(community.name, public_post.id)
             ]

      refute Enum.any?(
               page["orderedItems"],
               &String.contains?(&1["object"]["id"], Integer.to_string(followers_post.id))
             )

      refute Enum.any?(
               page["orderedItems"],
               &String.contains?(&1["object"]["id"], Integer.to_string(draft_post.id))
             )

      refute Enum.any?(
               page["orderedItems"],
               &String.contains?(&1["object"]["id"], Integer.to_string(disabled_post.id))
             )
    end

    test "serializes community polls as Question objects in the outbox", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityoutboxpollowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Outbox Poll #{unique}"})

      post = create_poll_post!(:community, owner, community)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/outbox", %{page: "1"})

      page = json_response(conn, 200)
      [item | _] = page["orderedItems"]
      assert item["type"] == "Create"
      assert item["object"]["type"] == "Question"
      assert item["object"]["id"] == ActivityPub.community_post_uri(community.name, post.id)
    end
  end

  describe "POST /c/:name/inbox" do
    setup do
      reset_inbox_rate_limit!()
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

    test "processes Create activities for community inboxes", %{
      conn: conn,
      community: community,
      group_actor: group_actor,
      remote_actor: remote_actor
    } do
      unique = System.unique_integer([:positive])
      note_id = "https://remote.example/notes/#{unique}"
      published = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/create/#{unique}",
        "type" => "Create",
        "actor" => remote_actor.uri,
        "to" => [group_actor.uri, "https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [ActivityPub.community_followers_uri(community.name)],
        "object" => %{
          "id" => note_id,
          "type" => "Note",
          "content" => "<p>Community hello</p>",
          "url" => note_id,
          "published" => published,
          "attributedTo" => remote_actor.uri,
          "to" => [group_actor.uri, "https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [ActivityPub.community_followers_uri(community.name)]
        }
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", activity)

      assert json_response(conn, 202) == %{}

      assert message = Messaging.get_message_by_activitypub_ref(note_id)
      assert message.remote_actor_id == remote_actor.id
      assert message.content == "Community hello"
    end

    test "does not persist follows from blocked instances", %{
      conn: conn,
      community: community,
      group_actor: group_actor,
      remote_actor: remote_actor
    } do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: remote_actor.domain, blocked: true})
        |> Repo.insert()

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
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
      assert ActivityPub.get_group_follow(remote_actor.id, group_actor.id) == nil
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
        |> Plug.Conn.assign(:activitypub_rate_limit_checked, true)
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", undo_activity)

      assert json_response(conn, 202) == %{}
      assert ActivityPub.get_group_follow(remote_actor.id, group_actor.id) == nil
    end

    test "removes persisted community follows on URI-form Undo", %{
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
        "object" => follow_id
      }

      conn =
        build_conn()
        |> Plug.Conn.assign(:activitypub_rate_limit_checked, true)
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", undo_activity)

      assert json_response(conn, 202) == %{}
      assert ActivityPub.get_group_follow(remote_actor.id, group_actor.id) == nil
    end

    test "returns 404 for non-public communities", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "privatecommunityowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Private Community #{unique}",
          is_public: false
        })

      remote_actor = remote_actor_fixture("privatecommunityfollower")

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => ActivityPub.community_actor_uri(community.name)
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", activity)

      assert json_response(conn, 404) == %{"error" => "Community not found"}
    end

    test "rejects structurally invalid community inbox activities", %{
      conn: conn,
      community: community,
      remote_actor: remote_actor
    } do
      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.uri
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", activity)

      assert json_response(conn, 400) == %{"error" => "Invalid activity"}
    end

    test "returns 503 for generic retryable community inbox failures", %{
      conn: conn,
      community: community,
      remote_actor: remote_actor
    } do
      missing_remote_target_uri =
        "https://remote.example/users/missing-move-target-#{System.unique_integer([:positive])}"

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Move",
        "actor" => remote_actor.uri,
        "object" => remote_actor.uri,
        "target" => missing_remote_target_uri
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/c/#{ActivityPub.community_slug(community.name)}/inbox", activity)

      assert json_response(conn, 503) == %{"error" => "Failed to fetch referenced actor"}
    end
  end

  describe "POST /users/:username/inbox" do
    setup do
      reset_inbox_rate_limit!()
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

    test "returns 404 for ActivityPub-disabled users", %{conn: conn} do
      user =
        AccountsFixtures.user_fixture(%{username: "disableinboxtest"})
        |> Ecto.Changeset.change(activitypub_enabled: false)
        |> Repo.update!()

      Elektrine.Accounts.Cached.invalidate_user_cache(user.id)

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

      assert json_response(conn, 404) == %{"error" => "User not found"}
    end

    test "rejects invalid-signature Delete requests", %{conn: conn, user: user} do
      signature_actor = remote_actor_fixture("invaliddelete")

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Delete",
        "actor" => "https://remote.example/users/someone",
        "object" => "https://remote.example/objects/123"
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, signature_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/users/#{user.username}/inbox", activity)

      assert json_response(conn, 401) == %{"error" => "Invalid or missing signature"}
    end

    test "rejects structurally invalid signed activities", %{conn: conn, user: user} do
      remote_actor = remote_actor_fixture("invalidfollowpayload")

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.uri
      }

      conn =
        conn
        |> Plug.Conn.assign(:valid_signature, true)
        |> Plug.Conn.assign(:signature_actor, remote_actor)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/users/#{user.username}/inbox", activity)

      assert json_response(conn, 400) == %{"error" => "Invalid activity"}
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

    test "normalizes invalid page params instead of raising", %{conn: conn} do
      hashtag = Elektrine.Social.get_or_create_hashtag("test")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag.normalized_name}", %{page: "foo"})

      response = json_response(conn, 200)

      assert response["type"] == "OrderedCollectionPage"

      assert response["id"] ==
               "#{ActivityPub.instance_url()}/tags/#{hashtag.normalized_name}?page=1"
    end

    test "only includes non-draft posts from ActivityPub-enabled local authors", %{conn: conn} do
      unique = System.unique_integer([:positive])
      hashtag_name = "federationtag#{unique}"
      enabled_user = AccountsFixtures.user_fixture(%{username: "federationenabled#{unique}"})

      disabled_user =
        AccountsFixtures.user_fixture(%{username: "federationdisabled#{unique}"})
        |> Ecto.Changeset.change(activitypub_enabled: false)
        |> Repo.update!()

      public_post = SocialFixtures.post_fixture(%{user: enabled_user})

      disabled_post =
        SocialFixtures.post_fixture(%{user: disabled_user})
        |> Repo.preload(:sender)

      draft_post =
        SocialFixtures.post_fixture(%{user: enabled_user})
        |> Ecto.Changeset.change(is_draft: true)
        |> Repo.update!()
        |> Repo.preload(:sender)

      Enum.each([public_post, disabled_post, draft_post], &attach_hashtag!(&1, hashtag_name))

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag_name}")

      response = json_response(conn, 200)
      assert response["totalItems"] == 1

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag_name}", %{page: "1"})

      page = json_response(conn, 200)

      assert Enum.map(page["orderedItems"], & &1["id"]) == [
               "#{ActivityPub.instance_url()}/users/#{enabled_user.username}/statuses/#{public_post.id}"
             ]

      refute Enum.any?(
               page["orderedItems"],
               &String.contains?(&1["id"], Integer.to_string(disabled_post.id))
             )

      refute Enum.any?(
               page["orderedItems"],
               &String.contains?(&1["id"], Integer.to_string(draft_post.id))
             )
    end

    test "serializes community polls with community object ids and excludes private communities",
         %{
           conn: conn
         } do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "hashtagcommunityowner#{unique}"})
      hashtag_name = "communitypolltag#{unique}"

      public_community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Public Hash #{unique}"})

      private_community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Private Hash #{unique}",
          is_public: false
        })

      public_post = create_poll_post!(:community, owner, public_community)
      private_post = create_poll_post!(:community, owner, private_community)

      Enum.each([public_post, private_post], &attach_hashtag!(&1, hashtag_name))

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag_name}")

      response = json_response(conn, 200)
      assert response["totalItems"] == 1

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag_name}", %{page: "1"})

      page = json_response(conn, 200)
      [item] = page["orderedItems"]

      assert item["type"] == "Question"
      assert item["id"] == ActivityPub.community_post_uri(public_community.name, public_post.id)
      refute String.contains?(item["id"], Integer.to_string(private_post.id))
    end

    test "serializes mirrored community posts as user objects with preserved routing", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "mirroredhashtagowner#{unique}"})
      hashtag_name = "mirroredtag#{unique}"
      remote_group = remote_group_actor_fixture("hashtagmirror")

      mirrored_community =
        SocialFixtures.community_conversation_fixture(owner, %{name: "Mirror Hash #{unique}"})
        |> Ecto.Changeset.change(
          is_federated_mirror: true,
          remote_group_actor_id: remote_group.id,
          federated_source: remote_group.uri
        )
        |> Repo.update!()

      post =
        SocialFixtures.discussion_post_fixture(%{user: owner, community: mirrored_community})
        |> attach_hashtag!(hashtag_name)

      assert :ok = Elektrine.ActivityPub.Outbox.federate_community_post(post, mirrored_community)

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/tags/#{hashtag_name}", %{page: "1"})

      page = json_response(conn, 200)
      [item] = page["orderedItems"]

      assert item["id"] ==
               "#{ActivityPub.instance_url()}/users/#{owner.username}/statuses/#{post.id}"

      assert item["audience"] == remote_group.uri
      assert item["cc"] == [remote_group.uri]
    end
  end

  describe "GET /c/:name/followers" do
    test "returns a paginated OrderedCollectionPage when page is requested", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityfollowersowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Followers Community #{unique}"
        })

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/followers", %{page: "foo"})

      response = json_response(conn, 200)

      assert response["type"] == "OrderedCollectionPage"

      assert response["id"] ==
               "#{ActivityPub.community_followers_uri(community.name)}?page=1"

      assert response["partOf"] == ActivityPub.community_followers_uri(community.name)
      assert response["orderedItems"] == []
    end

    test "does not count local community membership as ActivityPub followers", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityfollowcountowner#{unique}"})

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Follower Count Community #{unique}"
        })
        |> Ecto.Changeset.change(member_count: 7)
        |> Repo.update!()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{ActivityPub.community_slug(community.name)}/followers")

      response = json_response(conn, 200)
      assert response["totalItems"] == 0
    end
  end

  describe "GET /c/:name/moderators" do
    test "filters disabled moderators and keeps actor metadata in sync", %{conn: conn} do
      unique = System.unique_integer([:positive])
      owner = AccountsFixtures.user_fixture(%{username: "communityowner#{unique}"})
      moderator = AccountsFixtures.user_fixture(%{username: "communitymoderator#{unique}"})

      disabled_moderator =
        AccountsFixtures.user_fixture(%{username: "commdisabledmod#{unique}"})
        |> Ecto.Changeset.change(activitypub_enabled: false)
        |> Repo.update!()

      community =
        SocialFixtures.community_conversation_fixture(owner, %{
          name: "Moderated Community #{unique}"
        })

      assert {:ok, _owner_member} =
               Messaging.add_member_to_conversation(community.id, owner.id, "owner")

      assert {:ok, _moderator_member} =
               Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")

      assert {:ok, _disabled_member} =
               Messaging.add_member_to_conversation(
                 community.id,
                 disabled_moderator.id,
                 "moderator"
               )

      slug = ActivityPub.community_slug(community.name)
      owner_uri = "#{ActivityPub.instance_url()}/users/#{owner.username}"
      moderator_uri = "#{ActivityPub.instance_url()}/users/#{moderator.username}"

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{slug}/moderators")

      response = json_response(conn, 200)

      assert response["orderedItems"] == [owner_uri, moderator_uri]

      refute Enum.any?(
               response["orderedItems"],
               &String.contains?(&1, disabled_moderator.username)
             )

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/c/#{slug}")

      actor = json_response(conn, 200)
      assert actor["attributedTo"] == [owner_uri, moderator_uri]
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

  defp create_poll_post!(:timeline, user) do
    post =
      SocialFixtures.post_fixture(%{user: user})
      |> Ecto.Changeset.change(post_type: "poll", content: "", title: nil)
      |> Repo.update!()

    {:ok, _poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])

    post
    |> Ecto.Changeset.change(
      activitypub_id: ActivityPub.user_status_uri(user, post.id),
      activitypub_url: ActivityPub.user_status_uri(user, post.id)
    )
    |> Repo.update!()
    |> Repo.preload([:sender, :conversation])
  end

  defp create_poll_post!(:community, user, community) do
    post =
      SocialFixtures.discussion_post_fixture(%{user: user, community: community})
      |> Ecto.Changeset.change(post_type: "poll", content: "", title: "Community poll")
      |> Repo.update!()

    {:ok, _poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])

    post
    |> Ecto.Changeset.change(
      activitypub_id: ActivityPub.community_post_uri(community.name, post.id),
      activitypub_url: ActivityPub.community_post_web_url(community.name, post.id)
    )
    |> Repo.update!()
    |> Repo.preload([:sender, :conversation])
  end

  defp attach_hashtag!(message, hashtag_name) do
    hashtag = Social.get_or_create_hashtag(hashtag_name)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(Elektrine.Social.PostHashtag, [
      %{message_id: message.id, hashtag_id: hashtag.id, inserted_at: now}
    ])

    message
    |> Message.changeset(%{extracted_hashtags: [hashtag_name]})
    |> Repo.update!()
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

  defp remote_group_actor_fixture(label) do
    unique = System.unique_integer([:positive])
    slug = "#{label}#{unique}"
    uri = "https://remote.example/c/#{slug}"

    %Actor{}
    |> Actor.changeset(%{
      uri: uri,
      username: slug,
      domain: "remote.example",
      actor_type: "Group",
      inbox_url: "https://remote.example/c/#{slug}/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp verified_profile_custom_domain_fixture(user, domain) do
    {:ok, custom_domain} = Profiles.create_custom_domain(user, %{"domain" => domain})

    custom_domain
    |> Ecto.Changeset.change(
      status: "verified",
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()
    |> Repo.preload(:user)
  end

  defp set_handle!(user, handle) do
    user
    |> Ecto.Changeset.change(handle: handle)
    |> Repo.update!()
  end

  defp reset_inbox_rate_limit! do
    case :ets.whereis(:inbox_rate_limit) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end
end
