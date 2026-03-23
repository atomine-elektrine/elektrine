defmodule ElektrineWeb.RemoteUserLive.FollowButtonTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.Conversation
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp remote_actor_fixture(attrs) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        uri: "https://remote.example/users/remote#{unique}",
        username: "remote#{unique}",
        domain: "remote.example",
        display_name: "Remote #{unique}",
        inbox_url: "https://remote.example/inbox",
        public_key: "test-public-key"
      })

    %Actor{}
    |> Actor.changeset(attrs)
    |> Repo.insert!()
  end

  test "person follow button renders as a non-submit button", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    actor =
      remote_actor_fixture(%{
        uri: "https://mastodon.social/users/foodcoopbcn",
        username: "foodcoopbcn",
        domain: "mastodon.social",
        display_name: "Food Coop BCN",
        inbox_url: "https://mastodon.social/inbox"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/#{actor.username}@#{actor.domain}")

    document = Floki.parse_document!(html)

    buttons = Floki.find(document, ~s(button[phx-click="toggle_follow"]))

    assert length(buttons) == 1
    assert Enum.all?(buttons, &(Floki.attribute(&1, "type") == ["button"]))
  end

  test "notification-style remote user handles resolve cached actors", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    actor =
      remote_actor_fixture(%{
        uri: "https://mastodon.social/users/dansup",
        username: "dansup",
        domain: "mastodon.social",
        display_name: "Dan"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/@#{actor.username}@#{actor.domain}")

    assert html =~ "@#{actor.username}@#{actor.domain}"
  end

  test "community join buttons render as non-submit buttons", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    actor =
      remote_actor_fixture(%{
        actor_type: "Group",
        uri: "https://lemmy.example/c/test-community",
        username: "test-community",
        domain: "lemmy.example",
        display_name: "Test Community",
        inbox_url: "https://lemmy.example/inbox"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/#{actor.username}@#{actor.domain}")

    document = Floki.parse_document!(html)

    buttons = Floki.find(document, ~s(button[phx-click="toggle_follow"]))

    assert length(buttons) == 2
    assert Enum.all?(buttons, &(Floki.attribute(&1, "type") == ["button"]))
  end

  test "community handles preserve the ! prefix when resolving cached actors", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    actor =
      remote_actor_fixture(%{
        actor_type: "Group",
        uri: "https://lemmy.example/c/elixir",
        username: "elixir",
        domain: "lemmy.example",
        display_name: "Elixir",
        inbox_url: "https://lemmy.example/inbox"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/!#{actor.username}@#{actor.domain}")

    assert html =~ "!#{actor.username}@#{actor.domain}"
  end

  test "remote community page shows mirrored community posts stored on community conversations",
       %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    system_user = AccountsFixtures.user_fixture(%{username: "mirrorowner"})

    actor =
      remote_actor_fixture(%{
        actor_type: "Group",
        uri: "https://lemmy.example/c/elixir",
        username: "elixir",
        domain: "lemmy.example",
        display_name: "Elixir",
        inbox_url: "https://lemmy.example/inbox"
      })

    community =
      %Conversation{}
      |> Conversation.changeset(%{
        name: "elixir_lemmy_example",
        description: "mirror",
        type: "community",
        is_public: true,
        allow_public_posts: true,
        discussion_style: "forum",
        creator_id: system_user.id,
        is_federated_mirror: true,
        remote_group_actor_id: actor.id,
        federated_source: actor.uri
      })
      |> Repo.insert!()

    %Message{}
    |> Message.changeset(%{
      conversation_id: community.id,
      sender_id: system_user.id,
      remote_actor_id: actor.id,
      content: "Mirrored Lemmy post",
      visibility: "public",
      federated: true,
      post_type: "discussion",
      activitypub_id: "https://lemmy.example/post/123",
      activitypub_url: "https://lemmy.example/post/123",
      media_metadata: %{"community_actor_uri" => actor.uri, "type" => "Page"}
    })
    |> Repo.insert!()

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/!#{actor.username}@#{actor.domain}")

    assert html =~ "Mirrored Lemmy post"
  end

  test "local-domain handles redirect to the local profile route", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    user = AccountsFixtures.user_fixture(%{username: "maxfield"})
    expected_path = "/#{user.handle}"

    assert {:error, reason} =
             conn
             |> log_in_user(viewer)
             |> live("/remote/#{user.username}@#{ActivityPub.instance_domain()}")

    assert(
      case reason do
        {:live_redirect, %{to: ^expected_path}} -> true
        {:redirect, %{to: ^expected_path}} -> true
        _ -> false
      end
    )
  end
end
