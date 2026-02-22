defmodule Elektrine.Social.VotesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.Votes
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "vote_on_message/3" do
    test "creates an upvote on a post" do
      user = user_fixture()
      post = discussion_post_fixture()

      assert {:ok, vote} = Votes.vote_on_message(user.id, post.id, "up")
      assert vote.user_id == user.id
      assert vote.message_id == post.id
      assert vote.vote_type == "up"
    end

    test "creates a downvote on a post" do
      user = user_fixture()
      post = discussion_post_fixture()

      assert {:ok, vote} = Votes.vote_on_message(user.id, post.id, "down")
      assert vote.vote_type == "down"
    end

    test "updates upvotes/downvotes counts on the message" do
      user = user_fixture()
      post = discussion_post_fixture()

      assert post.upvotes == 0
      assert post.downvotes == 0

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 1
      assert updated_post.downvotes == 0
    end

    test "toggling same vote removes it" do
      user = user_fixture()
      post = discussion_post_fixture()

      # First vote
      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      assert Votes.get_user_vote(user.id, post.id) == "up"

      # Same vote again removes it
      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      assert Votes.get_user_vote(user.id, post.id) == nil

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 0
    end

    test "changing vote from up to down" do
      user = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      assert Votes.get_user_vote(user.id, post.id) == "up"

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "down")
      assert Votes.get_user_vote(user.id, post.id) == "down"

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 0
      assert updated_post.downvotes == 1
    end

    test "changing vote from down to up" do
      user = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "down")
      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")

      assert Votes.get_user_vote(user.id, post.id) == "up"

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 1
      assert updated_post.downvotes == 0
    end

    test "multiple users can vote on same post" do
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user1.id, post.id, "up")
      {:ok, _} = Votes.vote_on_message(user2.id, post.id, "up")
      {:ok, _} = Votes.vote_on_message(user3.id, post.id, "down")

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 2
      assert updated_post.downvotes == 1
    end

    test "updates score when voting" do
      user = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")

      updated_post = Repo.get!(Message, post.id)
      # Score should be calculated (exact value depends on algorithm)
      assert is_integer(updated_post.score)
    end
  end

  describe "get_user_vote/2" do
    test "returns vote type when user has voted" do
      user = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")

      assert Votes.get_user_vote(user.id, post.id) == "up"
    end

    test "returns nil when user has not voted" do
      user = user_fixture()
      post = discussion_post_fixture()

      assert Votes.get_user_vote(user.id, post.id) == nil
    end

    test "returns nil for different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user1.id, post.id, "up")

      assert Votes.get_user_vote(user1.id, post.id) == "up"
      assert Votes.get_user_vote(user2.id, post.id) == nil
    end
  end

  describe "get_message_voters/2" do
    test "returns upvoters and downvoters" do
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()
      post = discussion_post_fixture()

      {:ok, _} = Votes.vote_on_message(user1.id, post.id, "up")
      {:ok, _} = Votes.vote_on_message(user2.id, post.id, "up")
      {:ok, _} = Votes.vote_on_message(user3.id, post.id, "down")

      {upvoters, downvoters} = Votes.get_message_voters(post.id)

      assert length(upvoters) == 2
      assert length(downvoters) == 1

      upvoter_ids = Enum.map(upvoters, & &1.id)
      assert user1.id in upvoter_ids
      assert user2.id in upvoter_ids

      downvoter_ids = Enum.map(downvoters, & &1.id)
      assert user3.id in downvoter_ids
    end

    test "returns empty lists when no votes" do
      post = discussion_post_fixture()

      {upvoters, downvoters} = Votes.get_message_voters(post.id)

      assert upvoters == []
      assert downvoters == []
    end

    test "respects limit parameter" do
      post = discussion_post_fixture()
      users = for _ <- 1..5, do: user_fixture()

      for user <- users do
        {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      end

      {upvoters, _downvoters} = Votes.get_message_voters(post.id, 3)

      assert length(upvoters) == 3
    end
  end

  describe "get_message_voters_paginated/3" do
    test "returns paginated upvoters" do
      post = discussion_post_fixture()
      users = for _ <- 1..10, do: user_fixture()

      for user <- users do
        {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      end

      result = Votes.get_message_voters_paginated(post.id, "up", page: 1, per_page: 5)

      assert length(result.voters) == 5
      assert result.total == 10
      assert result.page == 1
      assert result.per_page == 5
      assert result.has_more == true
    end

    test "second page returns remaining voters" do
      post = discussion_post_fixture()
      users = for _ <- 1..10, do: user_fixture()

      for user <- users do
        {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      end

      result = Votes.get_message_voters_paginated(post.id, "up", page: 2, per_page: 5)

      assert length(result.voters) == 5
      assert result.has_more == false
    end

    test "returns empty for vote type with no votes" do
      post = discussion_post_fixture()
      user = user_fixture()

      {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")

      result = Votes.get_message_voters_paginated(post.id, "down")

      assert result.voters == []
      assert result.total == 0
    end
  end

  describe "calculate_engagement_score/3" do
    test "returns a score even for no votes" do
      post = discussion_post_fixture()

      score = Votes.calculate_engagement_score(post.id, 0, 0)

      # New posts get freshness bonus even with no votes
      assert is_integer(score)
      assert score >= 0
    end

    test "returns positive score for upvotes" do
      post = discussion_post_fixture()

      score = Votes.calculate_engagement_score(post.id, 10, 0)

      assert score > 0
    end

    test "returns lower score when more downvotes" do
      post = discussion_post_fixture()

      high_score = Votes.calculate_engagement_score(post.id, 10, 0)
      low_score = Votes.calculate_engagement_score(post.id, 10, 8)

      assert high_score > low_score
    end

    test "handles controversial content (balanced votes)" do
      post = discussion_post_fixture()

      # Controversial posts still get some score from controversy bonus
      score = Votes.calculate_engagement_score(post.id, 10, 10)

      assert is_integer(score)
    end

    test "handles message that doesn't exist" do
      # Falls back to simple calculation
      score = Votes.calculate_engagement_score(-1, 5, 2)

      # 5 - 2
      assert score == 3
    end
  end

  describe "vote integration" do
    test "vote counts remain accurate through multiple operations" do
      post = discussion_post_fixture()
      users = for _ <- 1..5, do: user_fixture()

      # All users upvote
      for user <- users do
        {:ok, _} = Votes.vote_on_message(user.id, post.id, "up")
      end

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 5
      assert updated_post.downvotes == 0

      # First 2 users change to downvote
      for user <- Enum.take(users, 2) do
        {:ok, _} = Votes.vote_on_message(user.id, post.id, "down")
      end

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 3
      assert updated_post.downvotes == 2

      # First user toggles off their downvote
      [first_user | _] = users
      {:ok, _} = Votes.vote_on_message(first_user.id, post.id, "down")

      updated_post = Repo.get!(Message, post.id)
      assert updated_post.upvotes == 3
      assert updated_post.downvotes == 1
    end
  end
end
