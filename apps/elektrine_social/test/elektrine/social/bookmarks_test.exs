defmodule Elektrine.Social.BookmarksTest do
  # Not async due to timing-dependent ordering tests
  use Elektrine.DataCase, async: false

  alias Elektrine.Social.{BookmarkFolders, Bookmarks}
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

    test "saving the same post twice is idempotent", %{user: user, post: post} do
      {:ok, _} = Bookmarks.save_post(user.id, post.id)
      assert {:ok, saved} = Bookmarks.save_post(user.id, post.id)
      assert saved.user_id == user.id
      assert saved.message_id == post.id
    end

    test "different users can save the same post", %{post: post} do
      user1 = user_fixture()
      user2 = user_fixture()

      assert {:ok, _} = Bookmarks.save_post(user1.id, post.id)
      assert {:ok, _} = Bookmarks.save_post(user2.id, post.id)
    end

    test "can assign a saved post to an owned folder", %{user: user, post: post} do
      {:ok, folder} = BookmarkFolders.create_folder(user.id, %{"name" => "Research"})

      assert {:ok, saved} = Bookmarks.save_post(user.id, post.id, folder_id: folder.id)
      assert saved.bookmark_folder_id == folder.id
    end

    test "rejects folders owned by another user", %{user: user, post: post} do
      other_user = user_fixture()
      {:ok, folder} = BookmarkFolders.create_folder(other_user.id, %{"name" => "Other"})

      assert {:error, :not_authorized} =
               Bookmarks.save_post(user.id, post.id, folder_id: folder.id)
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

    test "unsaving a post that is not saved is idempotent", %{user: user} do
      other_post = post_fixture()
      assert {:ok, nil} = Bookmarks.unsave_post(user.id, other_post.id)
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

    test "supports id pagination options" do
      user = user_fixture()
      older = post_fixture()
      newer = post_fixture()

      {:ok, _} = Bookmarks.save_post(user.id, older.id)
      {:ok, _} = Bookmarks.save_post(user.id, newer.id)

      result = Bookmarks.get_saved_posts(user.id, limit: 20, before_id: newer.id)
      assert Enum.map(result, & &1.id) == [older.id]

      result = Bookmarks.get_saved_posts(user.id, limit: 20, since_id: older.id)
      assert Enum.map(result, & &1.id) == [newer.id]
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
        from(m in Elektrine.Social.Message, where: m.id == ^post.id),
        set: [deleted_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

      result = Bookmarks.get_saved_posts(user.id)
      assert result == []
    end

    test "filters by bookmark folder" do
      user = user_fixture()
      {:ok, folder} = BookmarkFolders.create_folder(user.id, %{"name" => "Read later"})
      post_in_folder = post_fixture()
      other_post = post_fixture()

      {:ok, _} = Bookmarks.save_post(user.id, post_in_folder.id, folder_id: folder.id)
      {:ok, _} = Bookmarks.save_post(user.id, other_post.id)

      result = Bookmarks.get_saved_posts(user.id, folder_id: folder.id)

      assert Enum.map(result, & &1.id) == [post_in_folder.id]
    end
  end

  describe "get_saved_posts_with_cursor/2" do
    test "pages by keyset cursor without skipping after an unsave" do
      user = user_fixture()
      posts = for _ <- 1..5, do: post_fixture()
      for post <- posts, do: {:ok, _} = Bookmarks.save_post(user.id, post.id)

      {page1, cursor1} = Bookmarks.get_saved_posts_with_cursor(user.id, limit: 2)
      assert length(page1) == 2
      assert cursor1 == Bookmarks.saved_post_cursor(user.id, List.last(page1).id)

      # Unsaving an already-loaded post must not shift the continuation
      # (this is where offset pagination skipped items).
      {:ok, _} = Bookmarks.unsave_post(user.id, hd(page1).id)

      {page2, cursor2} = Bookmarks.get_saved_posts_with_cursor(user.id, limit: 2, cursor: cursor1)

      {page3, _cursor3} =
        Bookmarks.get_saved_posts_with_cursor(user.id, limit: 2, cursor: cursor2)

      paged_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)

      # No duplicates and nothing skipped: every saved post is seen exactly once.
      assert length(paged_ids) == 5
      assert Enum.sort(paged_ids) == posts |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "returns nil cursor for an empty page" do
      user = user_fixture()
      assert {[], nil} = Bookmarks.get_saved_posts_with_cursor(user.id)
    end

    test "breaks inserted_at ties by message id" do
      user = user_fixture()
      posts = for _ <- 1..4, do: post_fixture()
      # Saved in the same second, so inserted_at ties are expected.
      for post <- posts, do: {:ok, _} = Bookmarks.save_post(user.id, post.id)

      {page1, cursor} = Bookmarks.get_saved_posts_with_cursor(user.id, limit: 2)
      {page2, _} = Bookmarks.get_saved_posts_with_cursor(user.id, limit: 2, cursor: cursor)

      ids = Enum.map(page1 ++ page2, & &1.id)
      assert Enum.sort(ids) == posts |> Enum.map(& &1.id) |> Enum.sort()
      assert length(Enum.uniq(ids)) == 4
    end
  end

  describe "saved_item_folder_map/2" do
    test "maps message ids to folder ids for the user's saved items" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, folder} = BookmarkFolders.create_folder(user.id, %{"name" => "Read later"})
      in_folder = post_fixture()
      no_folder = post_fixture()
      not_saved = post_fixture()

      {:ok, _} = Bookmarks.save_post(user.id, in_folder.id, folder_id: folder.id)
      {:ok, _} = Bookmarks.save_post(user.id, no_folder.id)
      {:ok, _} = Bookmarks.save_post(other_user.id, not_saved.id)

      result =
        Bookmarks.saved_item_folder_map(user.id, [in_folder.id, no_folder.id, not_saved.id])

      assert result == %{in_folder.id => folder.id, no_folder.id => nil}
      assert Bookmarks.saved_item_folder_map(user.id, []) == %{}
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
