defmodule Elektrine.ActivityPub.RefreshCountsWorkerTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.RefreshCountsWorker
  alias Elektrine.Messaging
  alias Elektrine.Social.PostBoost
  alias Elektrine.Social.PostLike
  import Ecto.Query

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

  test "visible_refresh_candidate_ids/2 includes federated shared messages from boost wrappers" do
    posts = [
      %{
        id: 10,
        federated: false,
        activitypub_id: "https://local.example/users/alice/statuses/10",
        shared_message: %{
          id: 11,
          federated: true,
          activitypub_id: "https://remote.example/statuses/11"
        }
      },
      %{
        id: 12,
        federated: false,
        shared_message: %{
          id: 13,
          federated: false,
          activitypub_id: "https://local.example/statuses/13"
        }
      },
      %{
        id: 14,
        federated: true,
        activitypub_id: "https://remote.example/statuses/14",
        shared_message: %{
          id: 15,
          federated: true,
          activitypub_url: "https://remote.example/@alice/15"
        }
      }
    ]

    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 10) == [11, 14, 15]
    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 2) == [11, 14]
  end

  test "schedule_visible_refreshes/2 is disabled by default for feed page views" do
    posts = [
      %{id: 1, federated: true, activitypub_id: "https://remote.example/statuses/1"}
    ]

    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 10) == [1]
    assert RefreshCountsWorker.schedule_visible_refreshes(posts, limit: 10) == []
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

  test "refresh_single uses activitypub_url when activitypub_id is missing" do
    actor = remote_actor_fixture()
    unique = System.unique_integer([:positive])
    activitypub_url = "https://example.com/posts/#{unique}"

    {:ok, post} =
      Messaging.create_federated_message(%{
        content: "cached remote post",
        visibility: "public",
        activitypub_id: "https://example.com/activities/#{unique}",
        activitypub_url: activitypub_url,
        federated: true,
        remote_actor_id: actor.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })

    Repo.update_all(
      from(m in Elektrine.Social.Message, where: m.id == ^post.id),
      set: [activitypub_id: nil]
    )

    assert {:ok, true} =
             Cachex.put(:app_cache, {:object, activitypub_url}, {
               :ok,
               %{
                 "id" => activitypub_url,
                 "type" => "Note",
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "likes" => %{"totalItems" => 7},
                 "replies" => %{"totalItems" => 3},
                 "shares" => %{"totalItems" => 2}
               }
             })

    assert :ok =
             RefreshCountsWorker.perform(%Oban.Job{
               args: %{"type" => "refresh_single", "message_id" => post.id}
             })

    refreshed_post = Repo.get!(Elektrine.Social.Message, post.id)
    assert refreshed_post.like_count == 7
    assert refreshed_post.reply_count == 3
    assert refreshed_post.share_count == 2
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
