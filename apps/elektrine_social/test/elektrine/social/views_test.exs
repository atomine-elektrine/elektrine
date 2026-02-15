defmodule Elektrine.Social.ViewsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Social.Views
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "track_post_view/3" do
    test "records a post view" do
      user = user_fixture()
      post = post_fixture()

      assert {:ok, view} = Views.track_post_view(user.id, post.id)
      assert view.user_id == user.id
      assert view.message_id == post.id
    end

    test "records view with duration and completion status" do
      user = user_fixture()
      post = post_fixture()

      assert {:ok, view} =
               Views.track_post_view(user.id, post.id,
                 view_duration_seconds: 30,
                 completed: true
               )

      assert view.view_duration_seconds == 30
      assert view.completed == true
    end

    test "can track multiple views of the same post" do
      # The system allows multiple view records for analytics purposes
      # (e.g., user views post multiple times over different sessions)
      user = user_fixture()
      post = post_fixture()

      assert {:ok, view1} = Views.track_post_view(user.id, post.id)
      assert {:ok, view2} = Views.track_post_view(user.id, post.id)
      assert view1.id != view2.id
    end

    test "different users can view the same post" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      assert {:ok, _} = Views.track_post_view(user1.id, post.id)
      assert {:ok, _} = Views.track_post_view(user2.id, post.id)
    end
  end

  describe "get_user_viewed_posts/2" do
    test "returns list of viewed post IDs" do
      user = user_fixture()
      post1 = post_fixture()
      post2 = post_fixture()

      {:ok, _} = Views.track_post_view(user.id, post1.id)
      {:ok, _} = Views.track_post_view(user.id, post2.id)

      result = Views.get_user_viewed_posts(user.id)

      assert post1.id in result
      assert post2.id in result
    end

    test "returns viewed post IDs" do
      user = user_fixture()
      post1 = post_fixture()
      post2 = post_fixture()

      {:ok, _} = Views.track_post_view(user.id, post1.id)
      {:ok, _} = Views.track_post_view(user.id, post2.id)

      result = Views.get_user_viewed_posts(user.id)
      assert post1.id in result
      assert post2.id in result
    end

    test "respects limit option" do
      user = user_fixture()
      for _ <- 1..5, do: {:ok, _} = Views.track_post_view(user.id, post_fixture().id)

      result = Views.get_user_viewed_posts(user.id, limit: 3)
      assert length(result) == 3
    end

    test "respects days option" do
      user = user_fixture()
      post = post_fixture()

      {:ok, _} = Views.track_post_view(user.id, post.id)

      # Views from today should be included
      result = Views.get_user_viewed_posts(user.id, days: 1)
      assert post.id in result
    end

    test "returns empty list when user has no views" do
      user = user_fixture()
      result = Views.get_user_viewed_posts(user.id)
      assert result == []
    end
  end

  describe "get_post_view_count/1" do
    test "returns count of views" do
      post = post_fixture()

      assert Views.get_post_view_count(post.id) == 0

      {:ok, _} = Views.track_post_view(user_fixture().id, post.id)
      assert Views.get_post_view_count(post.id) == 1

      {:ok, _} = Views.track_post_view(user_fixture().id, post.id)
      assert Views.get_post_view_count(post.id) == 2
    end
  end

  describe "user_viewed_post?/2" do
    test "returns true when user has viewed the post" do
      user = user_fixture()
      post = post_fixture()

      refute Views.user_viewed_post?(user.id, post.id)

      {:ok, _} = Views.track_post_view(user.id, post.id)

      assert Views.user_viewed_post?(user.id, post.id)
    end

    test "returns false for different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      {:ok, _} = Views.track_post_view(user1.id, post.id)

      refute Views.user_viewed_post?(user2.id, post.id)
    end
  end
end
