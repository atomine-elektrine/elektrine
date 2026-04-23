defmodule Elektrine.Social.RecommendationsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts.UserActivityStats
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Recommendations

  describe "get_for_you_feed/2 visibility rules" do
    test "excludes followers-only posts from users the viewer does not follow" do
      viewer = user_fixture()
      public_author = user_fixture()
      restricted_author = user_fixture()

      public_post =
        post_fixture(%{
          user: public_author,
          content: "public post #{System.unique_integer([:positive])}"
        })

      followers_only_post =
        post_fixture(%{
          user: restricted_author,
          visibility: "followers",
          content: "followers post #{System.unique_integer([:positive])}"
        })

      set_like_count(public_post.id, 8)
      set_like_count(followers_only_post.id, 12)

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id, limit: 20)
        |> Enum.map(& &1.id)

      assert public_post.id in feed_ids
      refute followers_only_post.id in feed_ids
    end

    test "includes followers-only posts from followed users" do
      viewer = user_fixture()
      followed_author = user_fixture()

      {:ok, _follow} =
        %Follow{}
        |> Follow.changeset(%{
          follower_id: viewer.id,
          followed_id: followed_author.id
        })
        |> Repo.insert()

      followers_only_post =
        post_fixture(%{
          user: followed_author,
          visibility: "followers",
          content: "followed author post #{System.unique_integer([:positive])}"
        })

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id, limit: 20)
        |> Enum.map(& &1.id)

      assert followers_only_post.id in feed_ids
    end

    test "does not crash when filtering discussions for timeline posts" do
      viewer = user_fixture()
      author = user_fixture()

      timeline_post =
        post_fixture(%{
          user: author,
          content: "timeline post #{System.unique_integer([:positive])}"
        })

      set_like_count(timeline_post.id, 8)

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id, limit: 20, filter: "discussions")
        |> Enum.map(& &1.id)

      refute timeline_post.id in feed_ids
    end

    test "falls back to public community posts when discussion recommendations are empty" do
      previous = Application.get_env(:elektrine, :recommendations_enabled, true)
      Application.put_env(:elektrine, :recommendations_enabled, true)

      on_exit(fn ->
        Application.put_env(:elektrine, :recommendations_enabled, previous)
      end)

      viewer = user_fixture()
      author = user_fixture()

      discussion_post =
        discussion_post_fixture(%{
          user: author,
          content: "community discussion #{System.unique_integer([:positive])}"
        })

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id, limit: 20, filter: "discussions")
        |> Enum.map(& &1.id)

      assert discussion_post.id in feed_ids
    end
  end

  describe "get_for_you_feed/2 feature flag" do
    test "falls back to public timeline when recommendations are disabled" do
      previous = Application.get_env(:elektrine, :recommendations_enabled, true)
      Application.put_env(:elektrine, :recommendations_enabled, false)

      on_exit(fn ->
        Application.put_env(:elektrine, :recommendations_enabled, previous)
      end)

      viewer = user_fixture()
      public_author = user_fixture()
      followed_author = user_fixture()

      public_post =
        post_fixture(%{
          user: public_author,
          content: "public fallback #{System.unique_integer([:positive])}"
        })

      {:ok, _follow} =
        %Follow{}
        |> Follow.changeset(%{
          follower_id: viewer.id,
          followed_id: followed_author.id
        })
        |> Repo.insert()

      followers_only_post =
        post_fixture(%{
          user: followed_author,
          visibility: "followers",
          content: "followers-only fallback #{System.unique_integer([:positive])}"
        })

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id, limit: 20)
        |> Enum.map(& &1.id)

      assert public_post.id in feed_ids
      refute followers_only_post.id in feed_ids
    end
  end

  describe "record_view_with_dwell/3" do
    test "increments trust reading stats with dwell deltas" do
      viewer = user_fixture()
      post = post_fixture()

      assert {:ok, _view} =
               Recommendations.record_view_with_dwell(viewer.id, post.id, %{
                 dwell_time_ms: 1_200,
                 scroll_depth: 0.5,
                 source: "timeline"
               })

      assert {:ok, _view} =
               Recommendations.record_view_with_dwell(viewer.id, post.id, %{
                 dwell_time_ms: 1_800,
                 scroll_depth: 0.9,
                 source: "timeline"
               })

      stats = Repo.get_by!(UserActivityStats, user_id: viewer.id)
      assert stats.posts_read == 1
      assert stats.time_read_seconds == 3
    end
  end

  describe "get_for_you_feed/2 session adaptation" do
    test "boosts creators that the viewer engaged with in the current session" do
      viewer = user_fixture()
      preferred_author = user_fixture()
      other_author = user_fixture()

      preferred_post =
        post_fixture(%{
          user: preferred_author,
          content: "preferred creator post #{System.unique_integer([:positive])}"
        })

      other_post =
        post_fixture(%{
          user: other_author,
          content: "other creator post #{System.unique_integer([:positive])}"
        })

      set_like_count(preferred_post.id, 5)
      set_like_count(other_post.id, 5)
      set_inserted_at(preferred_post.id, ~N[2026-03-16 10:00:00])
      set_inserted_at(other_post.id, ~N[2026-03-16 11:00:00])

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id,
          limit: 20,
          session_context: %{
            liked_creators: [preferred_author.id],
            liked_local_creators: [preferred_author.id]
          }
        )
        |> Enum.map(& &1.id)

      assert Enum.find_index(feed_ids, &(&1 == preferred_post.id)) <
               Enum.find_index(feed_ids, &(&1 == other_post.id))
    end

    test "heavily penalizes posts dismissed in the current session" do
      viewer = user_fixture()
      author = user_fixture()

      keep_post =
        post_fixture(%{
          user: author,
          content: "keep me #{System.unique_integer([:positive])}"
        })

      dismissed_post =
        post_fixture(%{
          user: author,
          content: "dismiss me #{System.unique_integer([:positive])}"
        })

      set_like_count(keep_post.id, 6)
      set_like_count(dismissed_post.id, 6)

      feed_ids =
        Recommendations.get_for_you_feed(viewer.id,
          limit: 20,
          session_context: %{dismissed_posts: [dismissed_post.id]}
        )
        |> Enum.map(& &1.id)

      assert keep_post.id in feed_ids

      dismissed_index = Enum.find_index(feed_ids, &(&1 == dismissed_post.id))
      keep_index = Enum.find_index(feed_ids, &(&1 == keep_post.id))

      assert is_nil(dismissed_index) or keep_index < dismissed_index
    end
  end

  defp set_like_count(post_id, count) do
    from(m in Message, where: m.id == ^post_id)
    |> Repo.update_all(set: [like_count: count])
  end

  defp set_inserted_at(post_id, inserted_at) do
    from(m in Message, where: m.id == ^post_id)
    |> Repo.update_all(set: [inserted_at: inserted_at])
  end
end
