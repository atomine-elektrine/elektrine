defmodule Elektrine.Social.Votes do
  @moduledoc """
  Handles the voting system for discussion posts (upvotes/downvotes).

  This module implements a Reddit-style voting system with:
  - Upvote/downvote toggling
  - Wilson Score confidence interval for ranking
  - Time decay (Hacker News style)
  - Controversy scoring for engagement
  - Velocity bonuses for viral content

  ## Scoring Algorithm

  The engagement score combines multiple factors:
  1. Wilson Score - statistically confident ranking based on vote ratio
  2. Time Decay - newer content gets boost, decays over time
  3. Controversy - balanced votes indicate discussion
  4. Reply Bonus - discussions with replies get boosted
  5. Freshness Bonus - extra boost for very new content
  6. Velocity Score - rapid voting indicates viral content
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.MessageVote

  @doc """
  Votes on a message (upvote or downvote).

  ## Parameters
    - user_id: The ID of the user voting
    - message_id: The ID of the message being voted on
    - vote_type: Either "up" or "down"

  ## Returns
    - `{:ok, vote}` on success
    - `{:error, reason}` on failure

  ## Behavior
    - New vote: Creates the vote
    - Same vote type: Removes the vote (toggle off)
    - Different vote type: Updates to new vote type
  """
  def vote_on_message(user_id, message_id, vote_type) when vote_type in ["up", "down"] do
    case Repo.get_by(MessageVote, user_id: user_id, message_id: message_id) do
      nil ->
        # New vote
        create_vote(user_id, message_id, vote_type)

      %MessageVote{vote_type: ^vote_type} ->
        # Same vote, remove it (toggle off)
        remove_vote(user_id, message_id)

      %MessageVote{} = existing_vote ->
        # Different vote, update it
        update_vote(existing_vote, vote_type)
    end
  end

  @doc """
  Gets user's vote on a message.

  ## Returns
    - `"up"` if user upvoted
    - `"down"` if user downvoted
    - `nil` if user hasn't voted
  """
  def get_user_vote(user_id, message_id) do
    case Repo.get_by(MessageVote, user_id: user_id, message_id: message_id) do
      nil -> nil
      vote -> vote.vote_type
    end
  end

  @doc """
  Gets user's votes on multiple messages.

  ## Returns
  A map of message_id => vote_type ("up" or "down")
  """
  def get_user_votes(user_id, message_ids) when is_list(message_ids) do
    from(v in MessageVote,
      where: v.user_id == ^user_id and v.message_id in ^message_ids,
      select: {v.message_id, v.vote_type}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Gets the list of users who voted on a message.

  Returns `{upvoters, downvoters}` tuple with max 100 users each.
  For scalability, only returns first 100 voters of each type.
  """
  def get_message_voters(message_id, limit \\ 100) do
    upvoters =
      from(v in MessageVote,
        where: v.message_id == ^message_id and v.vote_type == "up",
        join: u in User,
        on: v.user_id == u.id,
        select: u,
        order_by: [desc: v.inserted_at],
        limit: ^limit
      )
      |> Repo.all()
      |> Repo.preload(:profile)

    downvoters =
      from(v in MessageVote,
        where: v.message_id == ^message_id and v.vote_type == "down",
        join: u in User,
        on: v.user_id == u.id,
        select: u,
        order_by: [desc: v.inserted_at],
        limit: ^limit
      )
      |> Repo.all()
      |> Repo.preload(:profile)

    {upvoters, downvoters}
  end

  @doc """
  Gets paginated voters for a message.

  ## Options
    - `:page` - Page number (default: 1)
    - `:per_page` - Results per page (default: 50)

  ## Returns
  A map with:
    - `:voters` - List of users
    - `:total` - Total count
    - `:page` - Current page
    - `:per_page` - Results per page
    - `:has_more` - Whether there are more results
  """
  def get_message_voters_paginated(message_id, vote_type, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    offset = (page - 1) * per_page

    query =
      from(v in MessageVote,
        where: v.message_id == ^message_id and v.vote_type == ^vote_type,
        join: u in User,
        on: v.user_id == u.id,
        select: u,
        order_by: [desc: v.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )

    total =
      from(v in MessageVote,
        where: v.message_id == ^message_id and v.vote_type == ^vote_type,
        select: count(v.id)
      )
      |> Repo.one()

    voters =
      query
      |> Repo.all()
      |> Repo.preload(:profile)

    %{
      voters: voters,
      total: total,
      page: page,
      per_page: per_page,
      has_more: total > offset + per_page
    }
  end

  @doc """
  Calculate engagement score using a complex algorithm inspired by Reddit's Best/Hot algorithms
  and Hacker News' ranking system, optimized for maximum engagement.

  ## Algorithm Components

  1. **Wilson Score** - Statistical confidence interval that favors high upvote ratio
     with many votes. Uses 95% confidence (z=1.96).

  2. **Time Decay** - Hacker News style gravity factor (1.5) that decays content
     score over time.

  3. **Controversy Score** - Boosts content where upvotes ≈ downvotes, indicating
     active discussion.

  4. **Engagement Multipliers**:
     - Reply bonus: Discussions with many replies get boosted
     - Length bonus: Thoughtful longer content gets slight boost
     - Link modifier: Slight penalty for link-only posts

  5. **Freshness Bonus** - Extra boost for content in first 2 hours

  6. **Velocity Score** - Rapid voting indicates viral/engaging content
  """
  def calculate_engagement_score(message_id, upvotes, downvotes) do
    # Get message details for time decay and reply count
    message =
      from(m in Message,
        where: m.id == ^message_id,
        select: %{
          inserted_at: m.inserted_at,
          reply_count: fragment("(SELECT COUNT(*) FROM messages WHERE reply_to_id = ?)", m.id),
          content_length: fragment("LENGTH(?)", m.content),
          has_link: fragment("? LIKE '%http%'", m.content)
        }
      )
      |> Repo.one()

    if message do
      # 1. Wilson Score Confidence Interval (Reddit's Best algorithm)
      # Gives statistically confident ranking, favors high upvote ratio with many votes
      total_votes = upvotes + downvotes

      wilson_score =
        if total_votes > 0 do
          # Calculate upvote ratio
          p = upvotes / total_votes

          # Z-score for 95% confidence
          z = 1.96

          # Wilson score formula
          numerator =
            p + z * z / (2 * total_votes) -
              z * :math.sqrt((p * (1 - p) + z * z / (4 * total_votes)) / total_votes)

          denominator = 1 + z * z / total_votes

          numerator / denominator * 100
        else
          0
        end

      # 2. Time Decay Factor (Hacker News style)
      # Newer content gets a boost but decays over time
      hours_old = NaiveDateTime.diff(NaiveDateTime.utc_now(), message.inserted_at, :second) / 3600

      # Gravity factor - higher = faster decay (1.8 is HN's value, 1.5 is gentler)
      gravity = 1.5
      time_factor = :math.pow(hours_old + 2, gravity)

      # 3. Controversy Score (encourages discussion)
      # High when upvotes ≈ downvotes with many votes
      controversy =
        if total_votes > 0 do
          balance = min(upvotes, downvotes) / max(max(upvotes, downvotes), 1)
          balance * total_votes * 0.5
        else
          0
        end

      # 4. Engagement Multipliers
      # Reply bonus - discussions with many replies get boosted
      reply_bonus = :math.log(max(message.reply_count + 1, 1)) * 5

      # Length bonus - longer thoughtful comments get slight boost
      # Handle nil content_length (encrypted messages)
      length_bonus = min((message.content_length || 0) / 500, 2)

      # Link penalty/bonus - links can be spam or valuable resources
      link_modifier = if message.has_link, do: 0.9, else: 1.0

      # 5. Freshness Bonus for very new content (first 2 hours)
      freshness_bonus =
        if hours_old < 2 do
          10 * (2 - hours_old)
        else
          0
        end

      # 6. Velocity Score (rapid voting indicates viral/engaging content)
      votes_per_hour =
        if hours_old > 0 do
          total_votes / max(hours_old, 0.1)
        else
          total_votes * 10
        end

      velocity_bonus = :math.log(max(votes_per_hour + 1, 1)) * 3

      # Combine all factors into final score
      # Wilson score is the base, modified by other factors
      base_score = wilson_score * link_modifier

      # Add engagement bonuses
      engagement_score =
        base_score +
          controversy * 0.3 +
          reply_bonus +
          length_bonus +
          freshness_bonus +
          velocity_bonus

      # Apply time decay to the final score
      final_score = engagement_score / time_factor

      # Ensure score doesn't go below simple vote difference for very positive content
      min_score = if upvotes > downvotes * 2, do: (upvotes - downvotes) / 2, else: final_score

      # Return rounded score
      round(max(final_score, min_score))
    else
      # Fallback to simple score
      upvotes - downvotes
    end
  end

  @doc """
  Recalculate scores for all messages using the new engagement algorithm.

  This is useful when deploying the new scoring system.
  Can be run in IEx: `Elektrine.Social.Votes.recalculate_all_scores()`

  ## Returns
    - `{:ok, count}` with number of messages updated
  """
  def recalculate_all_scores do
    messages =
      from(m in Message,
        where: not is_nil(m.conversation_id),
        select: %{id: m.id, upvotes: m.upvotes, downvotes: m.downvotes}
      )
      |> Repo.all()

    Enum.each(messages, fn msg ->
      score = calculate_engagement_score(msg.id, msg.upvotes || 0, msg.downvotes || 0)

      from(m in Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [score: score])
    end)

    {:ok, length(messages)}
  end

  @doc """
  Recalculate scores for recent discussion posts to maintain fresh rankings.

  This should be run periodically (e.g., every hour) to update time decay.
  Only processes posts from last 7 days that have engagement.

  ## Returns
    - `{:ok, %{posts: count, replies: count}}` with counts of updated items
  """
  def recalculate_recent_discussion_scores do
    # Get posts from last 7 days that have any engagement
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7 * 24 * 60 * 60, :second)

    messages =
      from(m in Message,
        where:
          not is_nil(m.conversation_id) and
            m.post_type == "discussion" and
            m.inserted_at > ^seven_days_ago and
            (m.upvotes > 0 or m.downvotes > 0 or
               fragment("(SELECT COUNT(*) FROM messages WHERE reply_to_id = ?)", m.id) > 0),
        select: %{id: m.id, upvotes: m.upvotes, downvotes: m.downvotes}
      )
      |> Repo.all()

    Enum.each(messages, fn msg ->
      score = calculate_engagement_score(msg.id, msg.upvotes || 0, msg.downvotes || 0)

      from(m in Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [score: score])
    end)

    # Also update scores for popular replies from recent discussions
    reply_messages =
      from(m in Message,
        where:
          not is_nil(m.conversation_id) and
            not is_nil(m.reply_to_id) and
            m.inserted_at > ^seven_days_ago and
            (m.upvotes > 0 or m.downvotes > 0),
        select: %{id: m.id, upvotes: m.upvotes, downvotes: m.downvotes}
      )
      |> Repo.all()

    Enum.each(reply_messages, fn msg ->
      score = calculate_engagement_score(msg.id, msg.upvotes || 0, msg.downvotes || 0)

      from(m in Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [score: score])
    end)

    {:ok, %{posts: length(messages), replies: length(reply_messages)}}
  end

  # Private Functions

  defp create_vote(user_id, message_id, vote_type) do
    case %MessageVote{}
         |> MessageVote.changeset(%{
           user_id: user_id,
           message_id: message_id,
           vote_type: vote_type
         })
         |> Repo.insert() do
      {:ok, vote} ->
        update_message_vote_counts(message_id)

        # Federate the vote and notify asynchronously
        Elektrine.Async.run(fn ->
          # Federate to ActivityPub
          case vote_type do
            "down" -> Elektrine.ActivityPub.Outbox.federate_dislike(message_id, user_id)
            "up" -> Elektrine.ActivityPub.Outbox.federate_like(message_id, user_id)
            _ -> :ok
          end

          # Notify post owner on upvotes (not downvotes)
          if vote_type == "up" do
            message = Repo.get(Message, message_id)

            if message && message.sender_id && message.sender_id != user_id do
              notify_post_upvote(user_id, message_id)
            end
          end
        end)

        {:ok, vote}

      error ->
        error
    end
  end

  defp remove_vote(user_id, message_id) do
    case Repo.get_by(MessageVote, user_id: user_id, message_id: message_id) do
      nil ->
        {:error, :not_found}

      vote ->
        vote_type = vote.vote_type

        case Repo.delete(vote) do
          {:ok, deleted_vote} ->
            update_message_vote_counts(message_id)

            # Federate the undo to ActivityPub
            Elektrine.Async.run(fn ->
              case vote_type do
                "down" -> Elektrine.ActivityPub.Outbox.federate_undo_dislike(message_id, user_id)
                "up" -> Elektrine.ActivityPub.Outbox.federate_unlike(message_id, user_id)
                _ -> :ok
              end
            end)

            {:ok, deleted_vote}

          error ->
            error
        end
    end
  end

  defp update_vote(vote, new_vote_type) do
    old_vote_type = vote.vote_type

    case vote
         |> MessageVote.changeset(%{vote_type: new_vote_type})
         |> Repo.update() do
      {:ok, updated_vote} ->
        update_message_vote_counts(vote.message_id)

        # Federate vote change to ActivityPub (undo old vote, send new vote)
        Elektrine.Async.run(fn ->
          # First undo the old vote
          case old_vote_type do
            "down" ->
              Elektrine.ActivityPub.Outbox.federate_undo_dislike(vote.message_id, vote.user_id)

            "up" ->
              Elektrine.ActivityPub.Outbox.federate_unlike(vote.message_id, vote.user_id)

            _ ->
              :ok
          end

          # Then send the new vote
          case new_vote_type do
            "down" -> Elektrine.ActivityPub.Outbox.federate_dislike(vote.message_id, vote.user_id)
            "up" -> Elektrine.ActivityPub.Outbox.federate_like(vote.message_id, vote.user_id)
            _ -> :ok
          end
        end)

        {:ok, updated_vote}

      error ->
        error
    end
  end

  defp update_message_vote_counts(message_id) do
    # Get vote counts
    vote_counts =
      from(v in MessageVote,
        where: v.message_id == ^message_id,
        group_by: v.vote_type,
        select: {v.vote_type, count(v.id)}
      )
      |> Repo.all()
      |> Enum.into(%{})

    upvotes = Map.get(vote_counts, "up", 0)
    downvotes = Map.get(vote_counts, "down", 0)

    # Calculate engagement score with advanced algorithm
    score = calculate_engagement_score(message_id, upvotes, downvotes)

    # Update message with new counts
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(set: [upvotes: upvotes, downvotes: downvotes, score: score])

    # Broadcast vote updates to discussion feeds (only for community posts)
    message = Repo.get!(Message, message_id) |> Repo.preload(:conversation)

    if message.conversation && message.conversation.type == "community" do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "discussion:#{message.conversation_id}",
        {:post_voted,
         %{message_id: message_id, upvotes: upvotes, downvotes: downvotes, score: score}}
      )
    end
  end

  # Notifies post owner when their post is upvoted
  defp notify_post_upvote(voter_id, message_id) do
    # Get the post and users
    message = Repo.get!(Message, message_id)

    # Don't notify if user voted on their own post
    # Only notify for local posts (federated posts don't have sender_id)
    if message.sender_id && voter_id != message.sender_id do
      # Check if user wants to be notified about likes
      user = Elektrine.Accounts.get_user!(message.sender_id)

      if Map.get(user, :notify_on_like, true) do
        voter = Elektrine.Accounts.get_user!(voter_id)

        Elektrine.Notifications.create_notification(%{
          user_id: message.sender_id,
          actor_id: voter_id,
          type: "like",
          title: "@#{voter.handle || voter.username} upvoted your post",
          url: "/timeline/post/#{message_id}",
          source_type: "message",
          source_id: message_id,
          priority: "low"
        })
      end
    end
  end
end
