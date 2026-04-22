defmodule Elektrine.Social.BlockedInstancesTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.{Actor, Instance}
  alias Elektrine.Messaging
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social

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

  defp block_instance!(domain) do
    %Instance{}
    |> Instance.changeset(%{domain: domain, blocked: true})
    |> Repo.insert!()
  end
end
