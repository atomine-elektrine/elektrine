defmodule Elektrine.Social.BoostsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Repo
  alias Elektrine.Social.Boosts
  alias Elektrine.Social.Message
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "boost_post/2" do
    test "boosts a post with content" do
      user = user_fixture()
      post = post_fixture(%{content: "Original content"})

      assert {:ok, boost} = Boosts.boost_post(user.id, post.id)
      assert boost.user_id == user.id
      assert boost.message_id == post.id
    end

    test "boosts a post with media but no content" do
      user = user_fixture()
      # Create media post with minimal content, then clear it
      post = media_post_fixture(%{content: "temp"})

      # Clear content but keep media
      Repo.update_all(
        Elektrine.Social.Message |> Ecto.Query.where(id: ^post.id),
        set: [content: ""]
      )

      assert {:ok, _boost} = Boosts.boost_post(user.id, post.id)
    end

    test "cannot boost an empty post (no content, no media)" do
      user = user_fixture()
      # Create a post with content first (validation requires it)
      post = post_fixture(%{content: "Original content"})

      # Directly update to empty content and no media to simulate edge case
      Repo.update_all(
        Elektrine.Social.Message |> Ecto.Query.where(id: ^post.id),
        set: [content: "", media_urls: []]
      )

      assert {:error, :empty_post} = Boosts.boost_post(user.id, post.id)
    end

    test "increments share count on the post" do
      user = user_fixture()
      post = post_fixture()

      assert post.share_count == 0

      {:ok, _} = Boosts.boost_post(user.id, post.id)

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 1
    end

    test "boosting the same post twice is idempotent" do
      user = user_fixture()
      post = post_fixture()

      {:ok, _} = Boosts.boost_post(user.id, post.id)
      assert {:ok, boost} = Boosts.boost_post(user.id, post.id)
      assert boost.user_id == user.id
      assert boost.message_id == post.id

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 1
    end

    test "different users can boost the same post" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      assert {:ok, _} = Boosts.boost_post(user1.id, post.id)
      assert {:ok, _} = Boosts.boost_post(user2.id, post.id)

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 2
    end

    test "remote post boosts add local boosts to the remote baseline" do
      user = user_fixture()

      post =
        post_fixture()
        |> Ecto.Changeset.change(
          share_count: 1,
          media_metadata: %{"original_share_count" => 20}
        )
        |> Repo.update!()

      assert {:ok, _} = Boosts.boost_post(user.id, post.id)

      assert %Message{share_count: 21} = Repo.get!(Message, post.id)
    end

    test "does not boost deleted posts" do
      user = user_fixture()

      post =
        post_fixture()
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update!()

      assert {:error, :not_found} = Boosts.boost_post(user.id, post.id)
    end
  end

  describe "unboost_post/2" do
    setup do
      user = user_fixture()
      post = post_fixture()
      {:ok, _} = Boosts.boost_post(user.id, post.id)
      %{user: user, post: post}
    end

    test "unboosts a post", %{user: user, post: post} do
      assert Boosts.user_boosted?(user.id, post.id)
      assert {:ok, _} = Boosts.unboost_post(user.id, post.id)
      refute Boosts.user_boosted?(user.id, post.id)
    end

    test "decrements share count on the post", %{user: user, post: post} do
      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 1

      {:ok, _} = Boosts.unboost_post(user.id, post.id)

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 0
    end

    test "unboosting after a remote refresh keeps the refreshed remote baseline" do
      user = user_fixture()

      post =
        post_fixture()
        |> Ecto.Changeset.change(
          remote_share_count: 20,
          remote_counts_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          share_count: 20
        )
        |> Repo.update!()

      {:ok, _} = Boosts.boost_post(user.id, post.id)

      post =
        Repo.get!(Message, post.id)
        |> Ecto.Changeset.change(
          remote_share_count: 21,
          remote_counts_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          share_count: 21
        )
        |> Repo.update!()

      assert {:ok, _} = Boosts.unboost_post(user.id, post.id)
      assert %Message{share_count: 21} = Repo.get!(Message, post.id)
    end

    test "unboosting a post that is not boosted is idempotent", %{user: user} do
      other_post = post_fixture()
      assert {:ok, nil} = Boosts.unboost_post(user.id, other_post.id)
    end
  end

  describe "create_quote_post/4" do
    test "creates a quote post with commentary" do
      user = user_fixture()
      original = post_fixture()

      assert {:ok, quote_post} = Boosts.create_quote_post(user.id, original.id, "My commentary")
      assert quote_post.sender_id == user.id
      assert quote_post.quoted_message_id == original.id
      assert quote_post.content == "My commentary"
    end

    test "increments quote count on original post" do
      user = user_fixture()
      original = post_fixture()

      {:ok, _} = Boosts.create_quote_post(user.id, original.id, "My commentary")

      updated_post = Repo.get!(Elektrine.Social.Message, original.id)
      assert updated_post.quote_count == 1
    end

    test "cannot create quote with empty content" do
      user = user_fixture()
      original = post_fixture()

      assert {:error, :empty_quote} = Boosts.create_quote_post(user.id, original.id, "")
      assert {:error, :empty_quote} = Boosts.create_quote_post(user.id, original.id, "   ")
    end

    test "respects visibility option" do
      user = user_fixture()
      original = post_fixture()

      {:ok, quote_post} =
        Boosts.create_quote_post(user.id, original.id, "My commentary", visibility: "followers")

      assert quote_post.visibility == "followers"
    end

    test "same user can quote same post multiple times" do
      user = user_fixture()
      original = post_fixture()

      assert {:ok, _} = Boosts.create_quote_post(user.id, original.id, "First commentary")
      assert {:ok, _} = Boosts.create_quote_post(user.id, original.id, "Second commentary")

      updated_post = Repo.get!(Elektrine.Social.Message, original.id)
      assert updated_post.quote_count == 2
    end
  end

  describe "user_boosted?/2" do
    test "returns true when user has boosted the post" do
      user = user_fixture()
      post = post_fixture()

      refute Boosts.user_boosted?(user.id, post.id)

      {:ok, _} = Boosts.boost_post(user.id, post.id)

      assert Boosts.user_boosted?(user.id, post.id)
    end

    test "returns false for different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = post_fixture()

      {:ok, _} = Boosts.boost_post(user1.id, post.id)

      refute Boosts.user_boosted?(user2.id, post.id)
    end
  end

  describe "boost and unboost integration" do
    test "share count stays accurate through multiple operations" do
      post = post_fixture()
      users = for _ <- 1..5, do: user_fixture()

      # All users boost the post
      for user <- users do
        {:ok, _} = Boosts.boost_post(user.id, post.id)
      end

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 5

      # First 3 users unboost
      for user <- Enum.take(users, 3) do
        {:ok, _} = Boosts.unboost_post(user.id, post.id)
      end

      updated_post = Repo.get!(Elektrine.Social.Message, post.id)
      assert updated_post.share_count == 2
    end
  end
end
