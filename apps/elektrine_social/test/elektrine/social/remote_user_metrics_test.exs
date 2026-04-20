defmodule ElektrineSocial.RemoteUser.MetricsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineSocial.RemoteUser.Metrics

  test "cache_community_stats persists counts to actor metadata" do
    actor = remote_group_actor_fixture()

    assert {:ok, %{members: 42, posts: 7}} =
             Metrics.cache_community_stats(actor, %{members: 42, posts: 7})

    refreshed = Repo.get!(Actor, actor.id)

    assert refreshed.metadata["subscriber_count"] == 42
    assert refreshed.metadata["posts_count"] == 7
    assert is_binary(refreshed.metadata["community_stats_fetched_at"])
    assert Metrics.cached_community_stats(actor.id) == %{members: 42, posts: 7}
  end

  test "cached_community_stats falls back to persisted actor metadata" do
    actor =
      remote_group_actor_fixture(%{
        metadata: %{"subscriber_count" => 15, "posts_count" => 4}
      })

    assert Metrics.cached_community_stats(actor.id) == %{members: 15, posts: 4}
  end

  test "cache_community_stats overwrites stale higher counts" do
    actor =
      remote_group_actor_fixture(%{
        metadata: %{"subscriber_count" => 42, "posts_count" => 7}
      })

    assert {:ok, %{members: 5, posts: 2}} =
             Metrics.cache_community_stats(actor, %{members: 5, posts: 2})

    refreshed = Repo.get!(Actor, actor.id)

    assert refreshed.metadata["subscriber_count"] == 5
    assert refreshed.metadata["posts_count"] == 2
    assert Metrics.cached_community_stats(actor.id) == %{members: 5, posts: 2}
  end

  defp remote_group_actor_fixture(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          uri: "https://groups#{unique}.example.com/c/test",
          username: "test#{unique}",
          domain: "groups#{unique}.example.com",
          inbox_url: "https://groups#{unique}.example.com/inbox",
          public_key: "test-public-key-#{unique}",
          actor_type: "Group",
          metadata: %{}
        },
        overrides
      )

    %Actor{}
    |> Actor.changeset(attrs)
    |> Repo.insert!()
  end
end
