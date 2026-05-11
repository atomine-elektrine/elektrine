defmodule Elektrine.Social.BlockedInstancesTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub.{Actor, Instance}
  alias Elektrine.ActivityPub.UserBlock, as: RemoteUserBlock
  alias Elektrine.Messaging
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.List

  test "get_public_federated_posts/1 excludes posts from blocked instances" do
    allowed_actor = remote_actor_fixture("allowed.example")
    blocked_actor = remote_actor_fixture("blocked.example")

    allowed_post = federated_post_fixture(allowed_actor)
    blocked_post = federated_post_fixture(blocked_actor)

    block_instance!("blocked.example")

    post_ids =
      Social.get_public_federated_posts(limit: 20)
      |> Enum.map(& &1.id)

    assert allowed_post.id in post_ids
    refute blocked_post.id in post_ids
  end

  test "public timeline excludes muted local senders for the viewer" do
    viewer = user_fixture()
    muted_user = user_fixture()
    visible_user = user_fixture()

    muted_post = post_fixture(%{user: muted_user})
    visible_post = post_fixture(%{user: visible_user})

    %UserMute{}
    |> UserMute.changeset(%{muter_id: viewer.id, muted_id: muted_user.id})
    |> Repo.insert!()

    post_ids =
      Social.get_public_timeline(limit: 20, user_id: viewer.id)
      |> Enum.map(& &1.id)

    assert visible_post.id in post_ids
    refute muted_post.id in post_ids
  end

  test "public federated timeline excludes viewer blocked remote actors and domains" do
    viewer = user_fixture()
    allowed_actor = remote_actor_fixture("allowed.example")
    blocked_actor = remote_actor_fixture("blocked-user.example")
    domain_actor = remote_actor_fixture("news.blocked-domain.example")

    allowed_post = federated_post_fixture(allowed_actor)
    blocked_post = federated_post_fixture(blocked_actor)
    domain_post = federated_post_fixture(domain_actor)

    %RemoteUserBlock{}
    |> RemoteUserBlock.changeset(%{
      user_id: viewer.id,
      blocked_uri: blocked_actor.uri,
      block_type: "user"
    })
    |> Repo.insert!()

    %RemoteUserBlock{}
    |> RemoteUserBlock.changeset(%{
      user_id: viewer.id,
      blocked_uri: "*.blocked-domain.example",
      block_type: "domain"
    })
    |> Repo.insert!()

    post_ids =
      Social.get_public_federated_posts(limit: 20, user_id: viewer.id)
      |> Enum.map(& &1.id)

    assert allowed_post.id in post_ids
    refute blocked_post.id in post_ids
    refute domain_post.id in post_ids
  end

  test "unlisted and followers-only posts stay out of public discovery but appear in home when followed" do
    viewer = user_fixture()
    followed = user_fixture()
    follow_local_user!(viewer.id, followed.id)

    public_post = post_fixture(%{user: followed, visibility: "public"})
    unlisted_post = post_fixture(%{user: followed, visibility: "unlisted"})
    followers_post = post_fixture(%{user: followed, visibility: "followers"})

    public_ids =
      Social.get_public_timeline(limit: 20, user_id: viewer.id)
      |> Enum.map(& &1.id)

    home_ids =
      Social.get_combined_feed(viewer.id, limit: 20)
      |> Enum.map(& &1.id)

    assert public_post.id in public_ids
    refute unlisted_post.id in public_ids
    refute followers_post.id in public_ids

    assert public_post.id in home_ids
    assert unlisted_post.id in home_ids
    assert followers_post.id in home_ids
  end

  test "list timeline applies viewer mute policy" do
    viewer = user_fixture()
    muted_user = user_fixture()
    visible_user = user_fixture()
    list = list_fixture(viewer)

    {:ok, _} = Social.add_to_list(list.id, %{user_id: muted_user.id})
    {:ok, _} = Social.add_to_list(list.id, %{user_id: visible_user.id})

    muted_post = post_fixture(%{user: muted_user})
    visible_post = post_fixture(%{user: visible_user})

    %UserMute{}
    |> UserMute.changeset(%{muter_id: viewer.id, muted_id: muted_user.id})
    |> Repo.insert!()

    post_ids =
      Social.get_list_timeline(list.id, limit: 20, viewer_id: viewer.id)
      |> Enum.map(& &1.id)

    assert visible_post.id in post_ids
    refute muted_post.id in post_ids
  end

  test "get_combined_feed/2 excludes followed remote posts from blocked wildcard instances" do
    viewer = user_fixture()
    allowed_actor = remote_actor_fixture("safe.example")
    blocked_actor = remote_actor_fixture("news.blocked.example")

    follow_remote_actor!(viewer.id, allowed_actor.id)
    follow_remote_actor!(viewer.id, blocked_actor.id)

    allowed_post = federated_post_fixture(allowed_actor)
    blocked_post = federated_post_fixture(blocked_actor)

    block_instance!("*.blocked.example")

    post_ids =
      Social.get_combined_feed(viewer.id, limit: 20)
      |> Enum.map(& &1.id)

    assert allowed_post.id in post_ids
    refute blocked_post.id in post_ids
  end

  defp federated_post_fixture(remote_actor) do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://#{remote_actor.domain}/posts/#{unique}"

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "Federated post #{unique}",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id
      })

    message
  end

  defp remote_actor_fixture(domain) do
    unique = System.unique_integer([:positive])
    username = "actor#{unique}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person"
    })
    |> Repo.insert!()
  end

  defp follow_remote_actor!(viewer_id, remote_actor_id) do
    %Follow{}
    |> Follow.changeset(%{follower_id: viewer_id, remote_actor_id: remote_actor_id})
    |> Repo.insert!()
  end

  defp follow_local_user!(viewer_id, followed_id) do
    %Follow{}
    |> Follow.changeset(%{follower_id: viewer_id, followed_id: followed_id})
    |> Repo.insert!()
  end

  defp block_instance!(domain) do
    %Instance{}
    |> Instance.changeset(%{domain: domain, blocked: true})
    |> Repo.insert!()
  end

  defp list_fixture(user) do
    %List{}
    |> List.changeset(%{
      user_id: user.id,
      name: "Test list #{System.unique_integer([:positive])}",
      visibility: "private"
    })
    |> Repo.insert!()
  end
end
