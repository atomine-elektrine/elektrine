defmodule ElektrineWeb.DiscussionsIndexLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
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

  test "signed-in users always see feed view button on communities view", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    assert has_element?(view, ~s(button[phx-value-view="feed"]))
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
      |> live(~p"/communities")

    html = render_async(view)

    assert has_element?(view, "h2", "Joined")
    assert has_element?(view, "h2", "Discover")
    assert has_element?(view, "h2", "Active Threads")
    assert html =~ joined_community.name
    assert html =~ discover_community.name
    assert has_element?(view, "h4", "Trending thread #{unique}")
  end

  test "overview renders federated active threads when conversation is not loaded", %{conn: conn} do
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
      |> live(~p"/communities")

    html = render_async(view)

    assert has_element?(view, "h2", "Active Threads")
    assert html =~ "Federated thread #{unique}"
    assert html =~ "!#{remote_actor.username}@#{remote_actor.domain}"
    assert html =~ ~s(href="/remote/post/)
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
      |> live(~p"/communities")

    html =
      view
      |> form("#community-search-form", query: matching_community.name)
      |> render_change()

    assert html =~ "Search Results"
    assert html =~ matching_community.name
    assert html =~ matching_community.description
  end

  test "composer param opens the community creation modal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?composer=community")

    assert render(view) =~ "Create Community"
  end
end
