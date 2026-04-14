defmodule Elektrine.ActivityPub.LemmyCommentBackfillTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.LemmyCommentBackfill
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message

  test "apply_comment_counts updates stored lemmy comment counters" do
    actor = remote_actor_fixture()

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "remote comment",
               visibility: "public",
               activitypub_id: "https://lemmy.example/comment/42",
               activitypub_url: "https://lemmy.example/comment/42",
               remote_actor_id: actor.id,
               like_count: 0,
               upvotes: 0,
               downvotes: 0,
               score: 0,
               reply_count: 0
             })

    assert 1 ==
             LemmyCommentBackfill.apply_comment_counts(%{
               message.activitypub_id => %{upvotes: 9, downvotes: 3, score: 6, child_count: 4}
             })

    refreshed = Repo.get!(Message, message.id)

    assert refreshed.like_count == 9
    assert refreshed.upvotes == 9
    assert refreshed.downvotes == 3
    assert refreshed.score == 6
    assert refreshed.reply_count == 4
  end

  test "apply_comment_counts supports dry run" do
    actor = remote_actor_fixture()

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "remote comment",
               visibility: "public",
               activitypub_id: "https://lemmy.example/comment/77",
               activitypub_url: "https://lemmy.example/comment/77",
               remote_actor_id: actor.id,
               like_count: 1,
               upvotes: 1,
               downvotes: 0,
               score: 1,
               reply_count: 0
             })

    assert 1 ==
             LemmyCommentBackfill.apply_comment_counts(
               %{message.activitypub_id => %{upvotes: 5, downvotes: 2, score: 3, child_count: 1}},
               dry_run: true
             )

    unchanged = Repo.get!(Message, message.id)

    assert unchanged.like_count == 1
    assert unchanged.upvotes == 1
    assert unchanged.downvotes == 0
    assert unchanged.score == 1
    assert unchanged.reply_count == 0
  end

  test "backfill_upvotes_from_like_count seeds existing lemmy comments" do
    actor = remote_actor_fixture()

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "remote comment",
               visibility: "public",
               activitypub_id: "https://lemmy.example/comment/88",
               activitypub_url: "https://lemmy.example/comment/88",
               remote_actor_id: actor.id,
               like_count: 11,
               upvotes: 0,
               downvotes: 0,
               score: 0,
               reply_count: 2
             })

    assert 1 == LemmyCommentBackfill.backfill_upvotes_from_like_count()

    refreshed = Repo.get!(Message, message.id)
    assert refreshed.upvotes == 11
    assert refreshed.like_count == 11
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://lemmy.example/users/test-#{unique}",
      username: "test#{unique}",
      domain: "lemmy.example",
      inbox_url: "https://lemmy.example/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----"
    })
    |> Repo.insert!()
  end
end
