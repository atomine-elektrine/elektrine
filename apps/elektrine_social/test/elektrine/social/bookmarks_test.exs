defmodule Elektrine.Social.BookmarksTest do
  # Not async due to timing-dependent ordering tests
  use Elektrine.DataCase, async: false

  alias Elektrine.Social.Bookmarks
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "save_post/2" do
    setup do
      user = user_fixture()
      post = post_fixture(%{user: user_fixture()})
      %{user: user, post: post}
    end

    test "saves a post for later", %{user: user, post: post} do
      assert {:ok, saved} = Bookmarks.save_post(user.id, post.id)
      assert saved.user_id == user.id
      assert saved.message_id == post.id
    end

    test "cannot save the same post twice", %{user: user, post: post} do
      {:ok, _} = Bookmarks.save_post(user.id, post.id)
      assert {:error, changeset} = Bookmarks.save_post(user.id, post.id)
      assert changeset.errors != []
    end

    test "different users can save the same post", %{post: post} do
      user1 = user_fixture()
      user2 = user_fixture()

      assert {:ok, _} = Bookmarks.save_post(user1.id, post.id)
      assert {:ok, _} = Bookmarks.save_post(user2.id, post.id)
    end
  end

  describe "unsave_post/2" do
    setup do
      user = user_fixture()
      post = post_fixture()
      {:ok, _} = Bookmarks.save_post(user.id, post.id)
      %{user: user, post: post}
    end

    test "removes a saved post", %{user: user, post: post} do
      assert Bookmarks.post_saved?(user.id, post.id)
      assert {:ok, _} = Bookmarks.unsave_post(user.id, post.id)
      refute Bookmarks.post_saved?(user.id, post.id)
    end

    test "returns error when post is not saved", %{user: user} do
      other_post = post_fixture()
      assert {:error, :not_saved} = Bookmarks.unsave_post(user.id, other_post.id)
    end
  end

  describe "post_saved?/2" do
    test "returns true when post is saved" do
      user = user_fixture()
      post = post_fixture()
      {:ok, _} = Bookmarks.save_post(user.id, post.id)

      assert Bookmarks.post_saved?(user.id, post.id)
    end

    test "returns false when post is not saved" do
      user = user_fixture()
      post = post_fixture()

      refute Bookmarks.post_saved?(user.id, post.id)
    end

    test "returns false for different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()
      {:ok, _} = Bookmarks.save_post(user1.id, post.id)

      refute Bookmarks.post_saved?(user2.id, post.id)
    end
  end

  describe "list_user_saved_posts/2" do
    test "returns MapSet of saved message IDs" do
      user = user_fixture()
      post1 = post_fixture()
      post2 = post_fixture()
      post3 = post_fixture()

      {:ok, _} = Bookmarks.save_post(user.id, post1.id)
      {:ok, _} = Bookmarks.save_post(user.id, post2.id)

      result = Bookmarks.list_user_saved_posts(user.id, [post1.id, post2.id, post3.id])

      assert MapSet.member?(result, post1.id)
      assert MapSet.member?(result, post2.id)
      refute MapSet.member?(result, post3.id)
    end

    test "returns empty MapSet when no posts are saved" do
      user = user_fixture()
      post = post_fixture()

      result = Bookmarks.list_user_saved_posts(user.id, [post.id])
      assert MapSet.size(result) == 0
    end

    test "handles empty list of message IDs" do
      user = user_fixture()
      result = Bookmarks.list_user_saved_posts(user.id, [])
      assert MapSet.size(result) == 0
    end
  end

  describe "get_saved_posts/2" do
    test "returns all saved posts" do
      user = user_fixture()
      post1 = post_fixture()
      post2 = post_fixture()
      post3 = post_fixture()

      {:ok, _} = Bookmarks.save_post(user.id, post1.id)
      {:ok, _} = Bookmarks.save_post(user.id, post2.id)
      {:ok, _} = Bookmarks.save_post(user.id, post3.id)

      result = Bookmarks.get_saved_posts(user.id)

      assert length(result) == 3
      result_ids = Enum.map(result, & &1.id)
      assert post1.id in result_ids
      assert post2.id in result_ids
      assert post3.id in result_ids
    end

    test "respects limit option" do
      user = user_fixture()
      for _ <- 1..5, do: {:ok, _} = Bookmarks.save_post(user.id, post_fixture().id)

      result = Bookmarks.get_saved_posts(user.id, limit: 3)
      assert length(result) == 3
    end

    test "respects offset option" do
      user = user_fixture()
      posts = for _ <- 1..5, do: post_fixture()
      for post <- posts, do: {:ok, _} = Bookmarks.save_post(user.id, post.id)

      result = Bookmarks.get_saved_posts(user.id, limit: 2, offset: 2)
      assert length(result) == 2
    end

    test "returns empty list when user has no saved posts" do
      user = user_fixture()
      result = Bookmarks.get_saved_posts(user.id)
      assert result == []
    end

    test "excludes deleted posts" do
      user = user_fixture()
      post = post_fixture()
      {:ok, _} = Bookmarks.save_post(user.id, post.id)

      # Soft-delete the post using update_all to avoid timestamp issues
      import Ecto.Query

      Repo.update_all(
        from(m in Elektrine.Messaging.Message, where: m.id == ^post.id),
        set: [deleted_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

      result = Bookmarks.get_saved_posts(user.id)
      assert result == []
    end
  end

  describe "count_saved_posts/1" do
    test "returns count of saved posts" do
      user = user_fixture()
      assert Bookmarks.count_saved_posts(user.id) == 0

      {:ok, _} = Bookmarks.save_post(user.id, post_fixture().id)
      assert Bookmarks.count_saved_posts(user.id) == 1

      {:ok, _} = Bookmarks.save_post(user.id, post_fixture().id)
      assert Bookmarks.count_saved_posts(user.id) == 2
    end

    test "counts are per-user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      {:ok, _} = Bookmarks.save_post(user1.id, post.id)

      assert Bookmarks.count_saved_posts(user1.id) == 1
      assert Bookmarks.count_saved_posts(user2.id) == 0
    end
  end
end
