defmodule Elektrine.Social.RecommendationsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Messaging.Message
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
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
  end

  defp set_like_count(post_id, count) do
    from(m in Message, where: m.id == ^post_id)
    |> Repo.update_all(set: [like_count: count])
  end
end
