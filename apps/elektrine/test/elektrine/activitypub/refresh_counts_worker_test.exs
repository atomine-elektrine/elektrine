defmodule Elektrine.ActivityPub.RefreshCountsWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.RefreshCountsWorker
  alias Elektrine.Messaging
  alias Elektrine.Social.PostBoost
  alias Elektrine.Social.PostLike

  test "visible_refresh_candidate_ids/2 selects visible federated ActivityPub posts" do
    posts = [
      %{id: 1, federated: true, activitypub_id: "https://remote.example/statuses/1"},
      %{id: 1, federated: true, activitypub_id: "https://remote.example/statuses/1"},
      %{
        id: 2,
        federated: true,
        activitypub_id: "",
        activitypub_url: "https://remote.example/@a/2"
      },
      %{id: 3, federated: false, activitypub_id: "https://remote.example/statuses/3"},
      %{id: nil, federated: true, activitypub_id: "https://remote.example/statuses/4"},
      %{id: 5, federated: true, activitypub_id: ""},
      %{"id" => 6, "federated" => true, "activitypub_id" => "https://remote.example/statuses/6"}
    ]

    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 10) == [1, 2, 6]
    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 2) == [1, 2]
    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 0) == []
    assert RefreshCountsWorker.visible_refresh_candidate_ids(:not_posts, limit: 10) == []
  end

  test "reconciles zero remote refreshes with local engagement rows" do
    user = AccountsFixtures.user_fixture()
    actor = remote_actor_fixture()
    unique = System.unique_integer([:positive])

    {:ok, post} =
      Messaging.create_federated_message(%{
        content: "cached remote post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}",
        activitypub_url: "https://remote.example/posts/#{unique}",
        federated: true,
        remote_actor_id: actor.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })

    %PostLike{}
    |> PostLike.changeset(%{user_id: user.id, message_id: post.id})
    |> Repo.insert!()

    %PostBoost{}
    |> PostBoost.changeset(%{user_id: user.id, message_id: post.id})
    |> Repo.insert!()

    {:ok, _reply} =
      Messaging.create_federated_message(%{
        content: "cached reply",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}/replies/1",
        federated: true,
        remote_actor_id: actor.id,
        reply_to_id: post.id
      })

    counts =
      RefreshCountsWorker.reconcile_refreshed_engagement_counts(post, %{
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })

    assert counts.like_count == 1
    assert counts.reply_count == 1
    assert counts.share_count == 1
  end

  test "reconciles zero remote refreshes with cached original counts" do
    actor = remote_actor_fixture()
    unique = System.unique_integer([:positive])

    {:ok, post} =
      Messaging.create_federated_message(%{
        content: "cached remote post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}",
        activitypub_url: "https://remote.example/posts/#{unique}",
        federated: true,
        remote_actor_id: actor.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0,
        media_metadata: %{
          "original_like_count" => 3,
          "original_reply_count" => 4,
          "original_share_count" => 5
        }
      })

    counts =
      RefreshCountsWorker.reconcile_refreshed_engagement_counts(post, %{
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })

    assert counts.like_count == 3
    assert counts.reply_count == 4
    assert counts.share_count == 5
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/alice-#{unique}",
      username: "alice#{unique}",
      domain: "remote.example",
      inbox_url: "https://remote.example/inbox",
      public_key: "test-public-key-#{unique}"
    })
    |> Repo.insert!()
  end
end
