defmodule Elektrine.ActivityPub.MRF.AntiFollowbotPolicyTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.MRF.AntiFollowbotPolicy
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  test "rejects obvious remote follow-bot actors following local users" do
    target = user_fixture()
    actor = remote_actor_fixture(%{username: "followbot"})
    activity = follow_activity(actor.uri, ActivityPub.actor_uri(target))

    assert {:reject, reason} = AntiFollowbotPolicy.filter(activity)
    assert reason =~ "rejected follow-bot actor"
  end

  test "rejects Service actors following local users" do
    target = user_fixture()
    actor = remote_actor_fixture(%{username: "relay", actor_type: "Service"})
    activity = follow_activity(actor.uri, ActivityPub.actor_uri(target))

    assert {:reject, _reason} = AntiFollowbotPolicy.filter(activity)
  end

  test "allows ordinary remote actors" do
    target = user_fixture()
    actor = remote_actor_fixture(%{username: "alice", display_name: "Alice"})
    activity = follow_activity(actor.uri, ActivityPub.actor_uri(target))

    assert {:ok, ^activity} = AntiFollowbotPolicy.filter(activity)
  end

  test "allows unknown remote actors without fetching during policy filtering" do
    target = user_fixture()

    activity =
      follow_activity(
        "https://unknown.example/users/followbot",
        ActivityPub.actor_uri(target)
      )

    assert {:ok, ^activity} = AntiFollowbotPolicy.filter(activity)
  end

  test "allows follow-bot actors already followed by the local target" do
    target = user_fixture()
    actor = remote_actor_fixture(%{username: "federationbot"})
    insert_local_remote_follow(target.id, actor.id)

    activity = follow_activity(actor.uri, ActivityPub.actor_uri(target))

    assert {:ok, ^activity} = AntiFollowbotPolicy.filter(activity)
  end

  test "does not reject follows targeting non-local actors" do
    actor = remote_actor_fixture(%{username: "followbot"})
    activity = follow_activity(actor.uri, "https://remote.example/users/bob")

    assert {:ok, ^activity} = AntiFollowbotPolicy.filter(activity)
  end

  defp follow_activity(actor_uri, object_uri) do
    %{
      "id" => "#{actor_uri}/activities/follow-1",
      "type" => "Follow",
      "actor" => actor_uri,
      "object" => object_uri
    }
  end

  defp remote_actor_fixture(attrs) do
    username = Map.get(attrs, :username, "remote")
    domain = Map.get(attrs, :domain, "#{username}.example")
    uri = Map.get(attrs, :uri, "https://#{domain}/users/#{username}")

    attrs =
      %{
        uri: uri,
        username: username,
        domain: domain,
        display_name: Map.get(attrs, :display_name, username),
        inbox_url: "#{uri}/inbox",
        public_key: "test-public-key",
        actor_type: Map.get(attrs, :actor_type, "Person")
      }

    %Actor{}
    |> Actor.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_local_remote_follow(follower_id, remote_actor_id) do
    %Follow{}
    |> Follow.changeset(%{
      follower_id: follower_id,
      remote_actor_id: remote_actor_id,
      pending: false
    })
    |> Repo.insert!()
  end
end
