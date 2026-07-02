defmodule Elektrine.Social.StatusPinsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message

  describe "pin_timeline_post/2" do
    test "pins an owned public timeline post" do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      assert {:ok, %Message{} = pinned} = Social.pin_timeline_post(user.id, post.id)
      assert pinned.is_pinned == true
      assert pinned.pinned_by_id == user.id
      assert pinned.pinned_at
    end

    test "is idempotent for an already pinned post" do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      assert {:ok, _pinned} = Social.pin_timeline_post(user.id, post.id)
      assert {:ok, repinned} = Social.pin_timeline_post(user.id, post.id)
      assert repinned.is_pinned == true
    end

    test "rejects posts owned by another user" do
      owner = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: owner, visibility: "public"})

      assert {:error, :unauthorized} = Social.pin_timeline_post(viewer.id, post.id)
      refute Repo.reload!(post).is_pinned
    end

    test "rejects non-profile visibility" do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "private"})

      assert {:error, :invalid_visibility} = Social.pin_timeline_post(user.id, post.id)
      refute Repo.reload!(post).is_pinned
    end

    test "enforces the profile pin limit" do
      user = user_fixture()

      posts =
        for _ <- 1..4 do
          post_fixture(%{user: user, visibility: "public"})
        end

      posts
      |> Enum.take(3)
      |> Enum.each(fn post ->
        assert {:ok, _pinned} = Social.pin_timeline_post(user.id, post.id)
      end)

      fourth = List.last(posts)
      assert {:error, :pin_limit_reached} = Social.pin_timeline_post(user.id, fourth.id)
      refute Repo.reload!(fourth).is_pinned
    end
  end

  describe "unpin_timeline_post/2" do
    test "unpins an owned timeline post" do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      assert {:ok, _pinned} = Social.pin_timeline_post(user.id, post.id)
      assert {:ok, unpinned} = Social.unpin_timeline_post(user.id, post.id)
      assert unpinned.is_pinned == false
      assert is_nil(unpinned.pinned_at)
      assert is_nil(unpinned.pinned_by_id)
    end

    test "is idempotent for an unpinned owned post" do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      assert {:ok, unpinned} = Social.unpin_timeline_post(user.id, post.id)
      assert unpinned.is_pinned == false
    end
  end
end
