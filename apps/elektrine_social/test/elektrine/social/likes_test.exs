defmodule Elektrine.Social.LikesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Repo
  alias Elektrine.Social.Likes
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "like_post/2" do
    test "likes a post" do
      user = user_fixture()
      post = post_fixture()

      assert {:ok, like} = Likes.like_post(user.id, post.id)
      assert like.user_id == user.id
      assert like.message_id == post.id
    end

    test "increments like count on the post" do
      user = user_fixture()
      post = post_fixture()

      assert post.like_count == 0

      {:ok, _} = Likes.like_post(user.id, post.id)

      # Reload the post to check the count
      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 1
    end

    test "cannot like the same post twice" do
      user = user_fixture()
      post = post_fixture()

      {:ok, _} = Likes.like_post(user.id, post.id)
      assert {:error, _changeset} = Likes.like_post(user.id, post.id)
    end

    test "different users can like the same post" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      assert {:ok, _} = Likes.like_post(user1.id, post.id)
      assert {:ok, _} = Likes.like_post(user2.id, post.id)

      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 2
    end
  end

  describe "unlike_post/2" do
    setup do
      user = user_fixture()
      post = post_fixture()
      {:ok, _} = Likes.like_post(user.id, post.id)
      %{user: user, post: post}
    end

    test "unlikes a post", %{user: user, post: post} do
      assert Likes.user_liked_post?(user.id, post.id)
      assert {:ok, _} = Likes.unlike_post(user.id, post.id)
      refute Likes.user_liked_post?(user.id, post.id)
    end

    test "decrements like count on the post", %{user: user, post: post} do
      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 1

      {:ok, _} = Likes.unlike_post(user.id, post.id)

      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 0
    end

    test "returns error when post is not liked", %{user: user} do
      other_post = post_fixture()
      assert {:error, :not_liked} = Likes.unlike_post(user.id, other_post.id)
    end
  end

  describe "user_liked_post?/2" do
    test "returns true when user has liked the post" do
      user = user_fixture()
      post = post_fixture()

      refute Likes.user_liked_post?(user.id, post.id)

      {:ok, _} = Likes.like_post(user.id, post.id)

      assert Likes.user_liked_post?(user.id, post.id)
    end

    test "returns false for different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      {:ok, _} = Likes.like_post(user1.id, post.id)

      refute Likes.user_liked_post?(user2.id, post.id)
    end
  end

  describe "list_user_likes/2" do
    test "returns list of liked message IDs" do
      user = user_fixture()
      post1 = post_fixture()
      post2 = post_fixture()
      post3 = post_fixture()

      {:ok, _} = Likes.like_post(user.id, post1.id)
      {:ok, _} = Likes.like_post(user.id, post2.id)

      result = Likes.list_user_likes(user.id, [post1.id, post2.id, post3.id])

      assert post1.id in result
      assert post2.id in result
      refute post3.id in result
    end

    test "returns empty list when no posts are liked" do
      user = user_fixture()
      post = post_fixture()

      result = Likes.list_user_likes(user.id, [post.id])
      assert result == []
    end

    test "handles empty list of message IDs" do
      user = user_fixture()
      result = Likes.list_user_likes(user.id, [])
      assert result == []
    end
  end

  describe "like and unlike integration" do
    test "like count stays accurate through multiple operations" do
      post = post_fixture()
      users = for _ <- 1..5, do: user_fixture()

      # All users like the post
      for user <- users do
        {:ok, _} = Likes.like_post(user.id, post.id)
      end

      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 5

      # First 3 users unlike
      for user <- Enum.take(users, 3) do
        {:ok, _} = Likes.unlike_post(user.id, post.id)
      end

      updated_post = Repo.get!(Elektrine.Messaging.Message, post.id)
      assert updated_post.like_count == 2
    end
  end
end
