defmodule Elektrine.Social.PollTest do
  use Elektrine.DataCase

  alias Elektrine.Social
  alias Elektrine.{Accounts, Messaging}

  describe "polls" do
    setup do
      # Create test user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      # Create test community
      {:ok, community} =
        Messaging.create_group_conversation(
          user.id,
          %{
            name: "testcommunity",
            description: "Test community",
            type: "community",
            is_public: true,
            allow_public_posts: true,
            discussion_style: "forum"
          },
          []
        )

      # Create a message for the poll
      {:ok, message} = Messaging.create_text_message(community.id, user.id, "Poll post")

      %{user: user, community: community, message: message}
    end

    test "create_poll creates a poll with options", %{message: message} do
      question = "What's your favorite color?"
      options = ["Red", "Blue", "Green"]

      {:ok, poll} = Social.create_poll(message.id, question, options)

      assert poll.question == question
      assert poll.total_votes == 0
      assert length(poll.options) == 3
      assert Enum.map(poll.options, & &1.option_text) |> Enum.sort() == options |> Enum.sort()
    end

    test "create_poll requires at least 2 options", %{message: message} do
      question = "Single option?"
      options = ["Only one"]

      result = Social.create_poll(message.id, question, options)

      assert {:error, "Poll must have at least 2 options"} = result
    end

    test "vote_on_poll records a vote", %{message: message, user: user} do
      {:ok, poll} = Social.create_poll(message.id, "Test poll?", ["Yes", "No"])
      [option1, _option2] = poll.options

      {:ok, _vote} = Social.vote_on_poll(poll.id, option1.id, user.id)

      # Check vote was recorded
      user_votes = Social.get_user_poll_votes(poll.id, user.id)
      assert option1.id in user_votes

      # Check counts updated
      results = Social.get_poll_results(poll.id)
      assert results.total_votes == 1
      option_result = Enum.find(results.options, &(&1.id == option1.id))
      assert option_result.vote_count == 1
      assert option_result.percentage == 100.0
    end

    test "vote_on_poll can toggle vote off", %{message: message, user: user} do
      {:ok, poll} = Social.create_poll(message.id, "Test?", ["Yes", "No"])
      [option1, _option2] = poll.options

      # Vote
      {:ok, _vote} = Social.vote_on_poll(poll.id, option1.id, user.id)

      # Vote again (toggle off)
      {:ok, _deleted} = Social.vote_on_poll(poll.id, option1.id, user.id)

      # Check vote was removed
      user_votes = Social.get_user_poll_votes(poll.id, user.id)
      assert option1.id not in user_votes

      # Check counts updated
      results = Social.get_poll_results(poll.id)
      assert results.total_votes == 0
    end

    test "vote_on_poll can change vote in single-choice poll", %{message: message, user: user} do
      {:ok, poll} = Social.create_poll(message.id, "Test?", ["Yes", "No"])
      [option1, option2] = poll.options

      # Vote for option 1
      {:ok, _vote} = Social.vote_on_poll(poll.id, option1.id, user.id)

      # Change to option 2
      {:ok, _vote} = Social.vote_on_poll(poll.id, option2.id, user.id)

      # Check only option 2 is voted
      user_votes = Social.get_user_poll_votes(poll.id, user.id)
      assert option1.id not in user_votes
      assert option2.id in user_votes

      # Check counts
      results = Social.get_poll_results(poll.id)
      assert results.total_votes == 1
      option2_result = Enum.find(results.options, &(&1.id == option2.id))
      assert option2_result.vote_count == 1
    end

    test "vote_on_poll allows multiple votes when allow_multiple is true", %{
      message: message,
      user: user
    } do
      {:ok, poll} =
        Social.create_poll(message.id, "Pick all that apply", ["A", "B", "C"],
          allow_multiple: true
        )

      [option1, option2, _option3] = poll.options

      # Vote for option 1
      {:ok, _} = Social.vote_on_poll(poll.id, option1.id, user.id)

      # Vote for option 2 (should keep both)
      {:ok, _} = Social.vote_on_poll(poll.id, option2.id, user.id)

      # Check both are voted
      user_votes = Social.get_user_poll_votes(poll.id, user.id)
      assert option1.id in user_votes
      assert option2.id in user_votes

      # Check counts
      results = Social.get_poll_results(poll.id)
      assert results.total_votes == 2
    end

    test "vote_on_poll rejects votes on closed polls", %{message: message, user: user} do
      # Create poll that closed 1 hour ago
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, poll} =
        Social.create_poll(message.id, "Closed poll?", ["Yes", "No"], closes_at: past_time)

      [option1, _] = poll.options

      # Try to vote
      result = Social.vote_on_poll(poll.id, option1.id, user.id)

      assert {:error, :poll_closed} = result
    end

    test "get_poll_results calculates percentages correctly", %{message: message} do
      {:ok, user1} =
        Accounts.create_user(%{
          username: "user1",
          password: "Password123!",
          password_confirmation: "Password123!"
        })

      {:ok, user2} =
        Accounts.create_user(%{
          username: "user2",
          password: "Password123!",
          password_confirmation: "Password123!"
        })

      {:ok, user3} =
        Accounts.create_user(%{
          username: "user3",
          password: "Password123!",
          password_confirmation: "Password123!"
        })

      {:ok, poll} = Social.create_poll(message.id, "Test?", ["A", "B"])
      [option1, option2] = poll.options

      # 2 votes for option1, 1 for option2
      Social.vote_on_poll(poll.id, option1.id, user1.id)
      Social.vote_on_poll(poll.id, option1.id, user2.id)
      Social.vote_on_poll(poll.id, option2.id, user3.id)

      results = Social.get_poll_results(poll.id)
      assert results.total_votes == 3

      option1_result = Enum.find(results.options, &(&1.id == option1.id))
      assert option1_result.vote_count == 2
      assert_in_delta option1_result.percentage, 66.7, 0.1

      option2_result = Enum.find(results.options, &(&1.id == option2.id))
      assert option2_result.vote_count == 1
      assert_in_delta option2_result.percentage, 33.3, 0.1
    end
  end
end
