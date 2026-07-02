defmodule Elektrine.Social.HomeFeedCacheInvalidationTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.CreateHandler
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Boosts
  alias Elektrine.Social.FeedPolicy
  alias Elektrine.Social.HashtagExtractor
  alias Elektrine.Social.HashtagFollows
  alias Elektrine.Social.HomeFeed
  alias Elektrine.Social.HomeFeedCache
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages

  test "inbound federated create fans out to followers home cache" do
    viewer = user_fixture()
    actor = remote_actor_fixture("example.org")

    assert {:ok, _follow} =
             %Follow{}
             |> Follow.changeset(%{
               follower_id: viewer.id,
               remote_actor_id: actor.id,
               pending: false
             })
             |> Repo.insert()

    object = %{
      "id" => "https://example.org/objects/1",
      "type" => "Note",
      "attributedTo" => actor.uri,
      "content" => "hello from remote",
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    assert {:ok, %Message{id: message_id}} = CreateHandler.create_note(object, actor.uri)
    message = Repo.get!(Message, message_id)
    assert message.remote_actor_id == actor.id
    assert viewer.id in HomeFeed.candidate_home_user_ids(message)
    assert FeedPolicy.visible_in_home?(viewer.id, message)
    assert message_id in HomeFeedCache.get(viewer.id)
  end

  test "followed hashtags are home feed candidates and fan out to cache" do
    viewer = user_fixture()
    author = user_fixture()

    assert {:ok, _follow} = HashtagFollows.follow_hashtag(viewer.id, "kairo")

    post = post_fixture(%{user: author, content: "building #kairo"})
    HashtagExtractor.process_hashtags_for_message(post.id, ["kairo"])

    reloaded = Repo.preload(Repo.get!(Message, post.id), [:hashtags])

    assert viewer.id in HomeFeed.candidate_home_user_ids(reloaded)
    assert FeedPolicy.visible_in_home?(viewer.id, reloaded)

    assert :ok = HomeFeed.fanout_message(reloaded.id)
    assert reloaded.id in HomeFeedCache.get(viewer.id)
  end

  test "combined feed fallback includes followed hashtag posts" do
    viewer = user_fixture()
    author = user_fixture()

    assert {:ok, _follow} = HashtagFollows.follow_hashtag(viewer.id, "kairo")

    followed_tag_post = post_fixture(%{user: author, content: "shipping #kairo"})
    HashtagExtractor.process_hashtags_for_message(followed_tag_post.id, ["kairo"])

    unrelated_post = post_fixture(%{user: author, content: "plain post"})

    HomeFeedCache.clear(viewer.id)
    posts = Elektrine.Social.get_combined_feed(viewer.id, limit: 20)
    ids = Enum.map(posts, & &1.id)

    assert followed_tag_post.id in ids
    refute unrelated_post.id in ids
  end

  test "remote actor mutes hide home posts without acting like hard blocks" do
    viewer = user_fixture()
    actor = remote_actor_fixture("muted-remote.example")

    assert {:ok, _follow} =
             %Follow{}
             |> Follow.changeset(%{
               follower_id: viewer.id,
               remote_actor_id: actor.id,
               pending: false
             })
             |> Repo.insert()

    conversation = timeline_conversation_fixture(viewer)

    message =
      %Message{
        conversation_id: conversation.id,
        content: "remote post from muted actor",
        message_type: "text",
        visibility: "public",
        post_type: "post",
        federated: true,
        remote_actor_id: actor.id,
        remote_actor: actor,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      }
      |> Repo.insert!()

    assert FeedPolicy.visible_in_home?(viewer.id, message)
    HomeFeedCache.put(viewer.id, [message.id])

    assert {:ok, _mute} = Accounts.mute_remote_actor(viewer.id, actor.id)
    assert HomeFeedCache.get(viewer.id) == []
    refute FeedPolicy.visible_in_home?(viewer.id, message)

    relationships = Elektrine.Social.TimelineRelationships.load(viewer.id, [message])
    assert Elektrine.Social.TimelineRelationships.muted_message?(relationships, message)

    refute Elektrine.Social.TimelineRelationships.blocked_message_except_mutes?(
             relationships,
             message
           )
  end

  test "follow clears the viewer home feed cache" do
    viewer = user_fixture()
    author = user_fixture()
    post = post_fixture(%{user: author})

    HomeFeedCache.put(viewer.id, [post.id])

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "unfollow clears the viewer home feed cache" do
    viewer = user_fixture()
    author = user_fixture()
    post = post_fixture(%{user: author})

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)
    HomeFeedCache.put(viewer.id, [post.id])

    assert {:ok, :unfollowed} = Profiles.unfollow_user(viewer.id, author.id)
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "unfollowed hashtag clears stale home feed cache" do
    viewer = user_fixture()
    post = post_fixture()

    assert {:ok, _follow} = HashtagFollows.follow_hashtag(viewer.id, "kairo")
    HomeFeedCache.put(viewer.id, [post.id])

    assert :ok = HashtagFollows.unfollow_hashtag(viewer.id, "kairo")
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "mute clears cached posts from the muted actor" do
    viewer = user_fixture()
    author = user_fixture()
    post = post_fixture(%{user: author})

    HomeFeedCache.put(viewer.id, [post.id])

    assert {:ok, _mute} = Accounts.mute_user(viewer.id, author.id)
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "block and domain block remove cached remote posts" do
    viewer = user_fixture()
    author = user_fixture()
    remote_post = remote_post_fixture()

    HomeFeedCache.put(viewer.id, [remote_post.id])
    assert {:ok, _block} = Accounts.block_user(viewer.id, author.id)
    assert HomeFeedCache.get(viewer.id) == []

    HomeFeedCache.put(viewer.id, [remote_post.id])
    assert {:ok, _instance} = ActivityPub.block_instance("example.org", "test", nil)
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "delete and visibility edit remove cached posts" do
    viewer = user_fixture()
    author = user_fixture()
    post = post_fixture(%{user: author, visibility: "public"})

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)
    HomeFeedCache.put(viewer.id, [post.id])

    assert {:ok, _deleted} = Messages.delete_message(post.id, author.id)
    assert HomeFeedCache.get(viewer.id) == []

    another_post = post_fixture(%{user: author, visibility: "public"})
    HomeFeedCache.put(viewer.id, [another_post.id])

    assert {:ok, _updated} = Messages.update_message(another_post, %{visibility: "private"})
    assert HomeFeedCache.get(viewer.id) == []
  end

  test "boost creates a feed entry and unboost removes it" do
    viewer = user_fixture()
    booster = user_fixture()
    original = post_fixture(%{visibility: "public"})

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, booster.id)
    assert {:ok, _boost} = Boosts.boost_post(booster.id, original.id)

    share_post_id = share_post_id!(booster.id, original.id)
    assert share_post_id in HomeFeedCache.get(viewer.id)

    assert {:ok, _deleted_boost} = Boosts.unboost_post(booster.id, original.id)
    refute share_post_id in HomeFeedCache.get(viewer.id)
  end

  defp share_post_id!(user_id, original_id) do
    Repo.one!(
      from m in Message,
        where: m.sender_id == ^user_id and m.shared_message_id == ^original_id,
        select: m.id
    )
  end

  defp remote_post_fixture do
    actor = remote_actor_fixture("example.org")

    conversation = timeline_conversation_fixture(user_fixture())

    %Message{
      conversation_id: conversation.id,
      content: "remote post",
      message_type: "text",
      visibility: "public",
      post_type: "post",
      federated: true,
      remote_actor_id: actor.id,
      like_count: 0,
      reply_count: 0,
      share_count: 0
    }
    |> Repo.insert!()
  end

  defp remote_actor_fixture(domain) do
    {:ok, actor} =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/alice",
        username: "alice",
        domain: domain,
        inbox_url: "https://#{domain}/users/alice/inbox",
        public_key: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
        actor_type: "Person",
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end
end
