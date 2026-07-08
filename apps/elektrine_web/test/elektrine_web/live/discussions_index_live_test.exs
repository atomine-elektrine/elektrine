defmodule ElektrineWeb.DiscussionsIndexLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures
  alias ElektrineSocialWeb.DiscussionsLive.Index
  alias ElektrineSocialWeb.DiscussionsLive.Operations.UiOperations
  alias ElektrineSocialWeb.DiscussionsLive.Operations.VotingOperations

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
  end

  test "stop_propagation is a no-op event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/communities")

    _ = render_hook(view, "stop_propagation", %{})

    assert Process.alive?(view.pid)
  end

  test "malformed community and actor action ids do not crash" do
    user = AccountsFixtures.user_fixture()
    socket = index_socket(%{current_user: user})

    assert {:noreply, socket} =
             Index.handle_event("join_community", %{"community_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to join community"

    assert {:noreply, socket} =
             Index.handle_event("leave_community", %{"community_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to leave community"

    assert {:noreply, socket} =
             Index.handle_event("follow_remote_group", %{"actor_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to follow community"

    assert {:noreply, socket} =
             Index.handle_event("unfollow_remote_community", %{"actor_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unfollow community"
  end

  test "malformed quick discussion community selectors do not crash" do
    user = AccountsFixtures.user_fixture()
    socket = index_socket(%{current_user: user})

    assert {:noreply, socket} =
             Index.handle_event(
               "create_quick_discussion",
               %{
                 "community_id" => "local:12abc",
                 "title" => "A title",
                 "content" => "Body",
                 "link_url" => ""
               },
               socket
             )

    assert socket.assigns.flash["error"] == "Please select a community"

    assert {:noreply, socket} =
             Index.handle_event(
               "create_quick_discussion",
               %{
                 "title" => "A title",
                 "content" => "Body",
                 "link_url" => ""
               },
               socket
             )

    assert socket.assigns.flash["error"] == "Please select a community"
  end

  test "malformed community voting ids do not crash" do
    user = AccountsFixtures.user_fixture()
    socket = index_socket(%{current_user: user})

    assert {:noreply, socket} =
             VotingOperations.handle_event(
               "vote",
               %{"message_id" => "12abc", "type" => "up"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to vote"

    assert {:noreply, socket} =
             VotingOperations.handle_event("show_voters", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to load voters"

    assert {:noreply, socket} =
             VotingOperations.handle_event(
               "vote_poll",
               %{"poll_id" => "12abc", "option_id" => "1"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to vote"

    assert {:noreply, socket} =
             VotingOperations.handle_event(
               "vote_remote_poll",
               %{"poll_id" => "remote-poll", "message_id" => "12abc", "option_name" => "Yes"},
               socket
             )

    assert socket.assigns.flash["error"] == "Unable to send remote poll vote"
  end

  test "malformed community UI ids and image payloads do not crash" do
    user = AccountsFixtures.user_fixture()

    socket =
      index_socket(%{
        current_user: user,
        community: %{id: 123, name: "test-community", hash: nil},
        discussion_posts: [],
        pinned_posts: []
      })

    assert {:noreply, socket} =
             UiOperations.handle_event(
               "report_discussion",
               %{"message_id" => "12abc"},
               socket
             )

    refute socket.assigns[:show_report_modal]

    assert {:noreply, socket} =
             UiOperations.handle_event(
               "view_original_context",
               %{"message_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Original content not found"

    assert {:noreply, socket} =
             UiOperations.handle_event(
               "open_image_modal",
               %{"images" => "not-json", "index" => "0"},
               socket
             )

    assert socket.assigns.flash["error"] == "Unable to open image"

    assert {:noreply, socket} =
             UiOperations.handle_event(
               "open_image_modal",
               %{
                 "images" => Jason.encode!(["/ok.png"]),
                 "index" => "abc",
                 "post_id" => "12abc"
               },
               socket
             )

    assert socket.assigns.flash["error"] == "Unable to open image"
  end

  test "signed-in users always see feed view button on communities view", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    assert has_element?(view, ~s(button[phx-value-view="feed"]))
  end

  test "new users with no community follows see an empty feed without public fallback", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])
    title = "Public fallback thread #{unique}"

    community =
      SocialFixtures.community_conversation_fixture(owner, %{
        name: "PublicFallback#{unique}",
        is_public: true
      })

    SocialFixtures.discussion_post_fixture(%{
      user: owner,
      community: community,
      title: title
    })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities")

    html = render_async(view)

    assert html =~ "Your community feed is empty"
    refute html =~ title
  end

  test "overview surfaces joined, discovery, and active thread sections", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    {:ok, joined_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "JoinedHub#{unique}",
          description: "Joined community description",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        [user.id]
      )

    {:ok, discover_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "DiscoverHub#{unique}",
          description: "Discover community description",
          type: "community",
          community_category: "art",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    SocialFixtures.discussion_post_fixture(%{
      user: owner,
      community: joined_community,
      title: "Joined thread #{unique}"
    })

    discover_community
    |> then(fn community ->
      SocialFixtures.discussion_post_fixture(%{
        user: owner,
        community: community,
        title: "Trending thread #{unique}"
      })
    end)
    |> Ecto.Changeset.change(%{score: 6, like_count: 6, reply_count: 2})
    |> Repo.update!()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    html = render_async(view)

    assert has_element?(view, "h2", "Discover Local Communities")
    refute has_element?(view, "h2", "Active Conversations")
    assert html =~ joined_community.name
    assert html =~ discover_community.name
    refute html =~ "Trending thread #{unique}"
  end

  test "joined overview keeps federated active threads out of the communities list", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/groups/federated-#{unique}",
        username: "federated#{unique}",
        domain: "remote.example",
        display_name: "Federated #{unique}",
        inbox_url: "https://remote.example/inbox",
        actor_type: "Group",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    assert {:ok, _message} =
             Messaging.create_federated_message(%{
               content: "Remote community discussion",
               title: "Federated thread #{unique}",
               visibility: "public",
               post_type: "discussion",
               activitypub_id: "https://remote.example/posts/#{unique}",
               activitypub_url: "https://remote.example/posts/#{unique}",
               remote_actor_id: remote_actor.id
             })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    html = render_async(view)

    refute has_element?(view, "h2", "Active Conversations")
    refute html =~ "Federated thread #{unique}"
  end

  test "community search replaces the overview with matching results", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    {:ok, matching_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "ElixirHub#{unique}",
          description: "Elixir makers community",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    {:ok, _other_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "GardenHub#{unique}",
          description: "Plants and gardens",
          type: "community",
          community_category: "general",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    html =
      view
      |> form("#community-search-form", query: matching_community.name)
      |> render_change()

    assert html =~ "Search Results"
    assert html =~ matching_community.name
    assert html =~ matching_community.description
  end

  test "discovery search supports scopes and saves recent searches", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    {:ok, matching_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "ScopedHub#{unique}",
          description: "Scoped search community",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    SocialFixtures.discussion_post_fixture(%{
      user: owner,
      community: matching_community,
      title: "Scoped thread #{unique}",
      content: "Scoped search body #{unique}"
    })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    _ = render_async(view)

    html =
      view
      |> form("#community-search-form", query: Integer.to_string(unique))
      |> render_submit()

    assert html =~ "Search Results"
    assert html =~ matching_community.name

    html =
      view
      |> element(~s(button[phx-click="set_search_scope"][phx-value-scope="posts"]))
      |> render_click()

    assert html =~ "Scoped thread #{unique}"

    html = render_click(view, "clear_community_search")

    refute html =~ "Search Results"
    assert html =~ "Category:"
  end

  test "overview renders joined communities and follow-based suggestions", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    {:ok, joined_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "FollowedSeed#{unique}",
          description: "Seed community",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        [user.id]
      )

    {:ok, suggested_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "FollowedSuggestion#{unique}",
          description: "Suggested community",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    html = render_async(view)

    assert html =~ "Because You Follow..."
    assert html =~ joined_community.name
    assert html =~ suggested_community.name
  end

  test "community action buttons are not nested inside links", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    owner = AccountsFixtures.user_fixture()
    unique = System.unique_integer([:positive])

    {:ok, joined_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "JoinedMarkup#{unique}",
          description: "Joined community description",
          type: "community",
          community_category: "programming",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        [user.id]
      )

    {:ok, search_community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "SearchMarkup#{unique}",
          description: "Searchable community description",
          type: "community",
          community_category: "general",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/groups/markup-#{unique}",
        username: "markup#{unique}",
        domain: "remote.example",
        display_name: "Markup #{unique}",
        inbox_url: "https://remote.example/inbox",
        actor_type: "Group",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    %Follow{}
    |> Follow.changeset(%{follower_id: user.id, remote_actor_id: remote_actor.id, pending: false})
    |> Repo.insert!()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    _ = render_async(view)

    refute has_element?(view, "a button")
    refute has_element?(view, "a #joined-leave-community-#{joined_community.id}")
    refute has_element?(view, "a #joined-unfollow-community-#{remote_actor.id}")

    view
    |> form("#community-search-form", query: search_community.name)
    |> render_change()

    refute has_element?(view, "a #search-join-community-#{search_community.id}")
  end

  test "composer param opens the community creation modal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?composer=community")

    assert render(view) =~ "Create Community"
  end

  test "community feed vote broadcast updates score without dropping voted state" do
    post = %{
      id: 101,
      activitypub_id: "https://remote.example/posts/101",
      score: 5,
      upvotes: 5,
      downvotes: 0,
      like_count: 5,
      reply_count: 2,
      share_count: 0,
      federated: true,
      remote_actor_id: nil,
      sender_id: nil,
      title: "Feed vote test",
      content: "",
      media_urls: [],
      inserted_at: ~N[2026-04-13 12:00:00]
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        followed_community_posts: [post],
        filtered_community_posts: [post],
        federated_discussions: [],
        filtered_federated_discussions: [],
        trending_discussions: [],
        filtered_discussions: [],
        lemmy_counts: %{"https://remote.example/posts/101" => %{score: 5, comments: 2}},
        post_interactions: %{
          "https://remote.example/posts/101" => %{
            liked: true,
            downvoted: false,
            vote: "up",
            vote_delta: 1,
            like_delta: 0
          }
        },
        feed_sort: "top",
        session_context: nil
      }
    }

    assert {:noreply, updated_socket} =
             Index.handle_info(
               {:post_voted, %{message_id: 101, upvotes: 6, downvotes: 0, score: 6}},
               socket
             )

    assert hd(updated_socket.assigns.filtered_community_posts).score == 6
    assert updated_socket.assigns.lemmy_counts["https://remote.example/posts/101"].score == 6

    assert updated_socket.assigns.post_interactions["https://remote.example/posts/101"].vote ==
             "up"

    assert updated_socket.assigns.post_interactions["https://remote.example/posts/101"].vote_delta ==
             0
  end

  test "community count refresh candidates include remote ActivityPub posts without actors" do
    posts = [
      %{id: 1, federated: true, remote_actor_id: nil, activitypub_id: "https://remote.test/1"},
      %{id: 1, federated: true, remote_actor_id: nil, activitypub_id: "https://remote.test/1"},
      %{id: 2, federated: true, remote_actor_id: 10, activitypub_url: "https://remote.test/2"},
      %{id: 3, federated: true, remote_actor_id: 10, activitypub_id: ""},
      %{id: 4, federated: false, remote_actor_id: 10, activitypub_id: "https://remote.test/4"}
    ]

    assert Index.visible_remote_count_refresh_ids(posts, 10) == [1, 2]
  end

  defp index_socket(assigns) do
    base_assigns = %{
      __changed__: %{},
      flash: %{},
      communities: [],
      followed_remote_communities: [],
      discover_remote_communities: [],
      selected_category: "all",
      joined_community_ids: MapSet.new(),
      pending_media_urls: [],
      pending_media_attachments: [],
      pending_media_alt_texts: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base_assigns, assigns)}
  end
end
