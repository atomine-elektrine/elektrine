defmodule Elektrine.Social.Recommendations do
  @moduledoc """
  Advanced content recommendation engine with sophisticated ranking algorithms.

  Features:
  - Dwell time analysis (time spent = interest signal)
  - Negative signals (dismissals, scroll-past detection)
  - Session-aware adaptation (real-time preference learning)
  - Explore/exploit balance (discovery vs. known interests)
  - Interest decay (recent interests weighted more)
  - Two-stage retrieval (fast candidate generation + expensive ranking)
  - Satisfaction scoring (quality over clickbait)
  - Collaborative filtering (what similar users like)
  - Trending detection (engagement velocity)
  - Diversity enforcement (prevent echo chambers)
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.{Messaging.Message, Social}
  alias Elektrine.Social.{PostView, PostDismissal, CreatorSatisfaction}

  # Configuration
  @min_score_threshold 10
  # 15% of feed is exploration
  @exploration_ratio 0.15
  # Half-life decay factor
  @interest_decay_rate 0.1
  @max_consecutive_same_creator 3
  # 30 seconds = engaged
  @dwell_time_threshold_engaged 30_000
  # 10 seconds = interested
  @dwell_time_threshold_interested 10_000
  # 3 seconds = glanced
  @dwell_time_threshold_glanced 3_000

  @doc """
  Gets personalized recommendation feed for a user.

  ## Options
  - `:limit` - Maximum posts to return (default: 50)
  - `:session_context` - Map with session engagement data for real-time adaptation
  """
  def get_for_you_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    session_context = Keyword.get(opts, :session_context, %{})

    # Build user profile with session context
    user_profile = build_user_profile(user_id, session_context)

    # Stage 1: Fast candidate generation (broad net)
    candidates = get_candidate_posts_fast(user_id, limit * 10)

    # Stage 2: Quick score for pre-filtering
    pre_scored =
      candidates
      |> Enum.map(fn post -> {post, score_post_quick(post, user_profile)} end)
      |> Enum.sort_by(fn {_post, score} -> score end, :desc)
      |> Enum.take(limit * 3)

    # Stage 3: Expensive full scoring on reduced set
    fully_scored =
      pre_scored
      |> Enum.map(fn {post, _quick_score} ->
        {post, score_post_full(post, user_profile, user_id)}
      end)
      |> Enum.filter(fn {post, score} ->
        score >= @min_score_threshold or qualifies_for_feed?(post, user_profile)
      end)
      |> Enum.sort_by(fn {_post, score} -> score end, :desc)

    # Split into exploit (personalized) and explore (discovery) pools
    {exploit_posts, explore_candidates} = split_for_exploration(fully_scored, user_profile)

    # Take main feed posts
    main_feed =
      exploit_posts
      |> Enum.take(ceil(limit * (1 - @exploration_ratio)))
      |> Enum.map(fn {post, _score} -> post end)

    # Add exploration posts (high-quality content outside normal interests)
    exploration_count = ceil(limit * @exploration_ratio)

    explore_posts =
      explore_candidates
      |> Enum.filter(fn {post, _score} -> (post.like_count || 0) >= 5 end)
      |> Enum.take_random(exploration_count)
      |> Enum.map(fn {post, _score} -> post end)

    # Interleave exploration throughout feed
    interleaved = interleave_posts(main_feed, explore_posts)

    # Final diversification
    diversify_feed(interleaved)
  end

  # Posts that always qualify regardless of score
  defp qualifies_for_feed?(post, user_profile) do
    cond do
      post.sender_id in user_profile.followed_users -> true
      post.federated && post.remote_actor_id in user_profile.followed_remote_actors -> true
      (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0) >= 5 -> true
      (post.media_urls || []) != [] && (post.like_count || 0) >= 2 -> true
      true -> false
    end
  end

  # Build comprehensive user profile with session awareness
  defp build_user_profile(user_id, session_context) do
    %{
      # Core signals
      liked_posts: get_user_liked_posts(user_id),
      viewed_posts: get_user_viewed_posts(user_id),
      followed_users: get_followed_user_ids(user_id),
      followed_remote_actors: get_followed_remote_actor_ids(user_id),

      # Interest signals with decay
      favorite_hashtags: get_user_favorite_hashtags_with_decay(user_id),
      favorite_categories: get_user_favorite_categories(user_id),
      preferred_communities: get_user_communities(user_id),
      favorite_domains: get_user_favorite_domains(user_id),

      # Engagement signals
      engagement_types: analyze_engagement_types(user_id),
      viewed_creators: get_viewed_creator_ids(user_id),
      liked_by_followed: get_posts_liked_by_followed(user_id),

      # Dwell time data
      creator_dwell_times: get_creator_avg_dwell_times(user_id),
      high_engagement_hashtags: get_high_dwell_hashtags(user_id),

      # Negative signals
      dismissed_posts: get_dismissed_post_ids(user_id),
      creator_ignore_rates: get_creator_ignore_rates(user_id),
      dismissed_hashtags: get_frequently_dismissed_hashtags(user_id),

      # Satisfaction data
      creator_satisfaction: get_creator_satisfaction_scores(user_id),

      # Session context (real-time adaptation)
      session_liked_hashtags: Map.get(session_context, :liked_hashtags, []),
      session_liked_creators: Map.get(session_context, :liked_creators, []),
      session_liked_local_creators:
        Map.get(
          session_context,
          :liked_local_creators,
          Map.get(session_context, :liked_creators, [])
        ),
      session_liked_remote_creators: Map.get(session_context, :liked_remote_creators, []),
      session_engagement_rate: Map.get(session_context, :engagement_rate, 0.0),
      session_viewed_posts: Map.get(session_context, :viewed_posts, [])
    }
  end

  # ==============================================================================
  # TWO-STAGE RETRIEVAL
  # ==============================================================================

  # Stage 1: Fast candidate generation with cheap filters
  defp get_candidate_posts_fast(user_id, limit) do
    blocked_user_ids = Elektrine.Accounts.list_blocked_users(user_id) |> Enum.map(& &1.id)
    blocked_by_user_ids = Elektrine.Accounts.list_users_who_blocked(user_id) |> Enum.map(& &1.id)
    followed_user_ids = get_followed_user_ids(user_id)
    all_blocked_ids = (blocked_user_ids ++ blocked_by_user_ids) |> Enum.uniq()

    thirty_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-30, :day)

    scope_and_visibility_filter =
      if Enum.empty?(followed_user_ids) do
        dynamic(
          [m, c],
          (c.type == "timeline" and
             m.post_type in ["post", "gallery"] and
             m.visibility == "public") or
            (c.type == "community" and m.post_type == "discussion" and c.is_public == true)
        )
      else
        dynamic(
          [m, c],
          (c.type == "timeline" and
             m.post_type in ["post", "gallery"] and
             (m.visibility == "public" or
                (m.visibility == "followers" and m.sender_id in ^followed_user_ids))) or
            (c.type == "community" and m.post_type == "discussion" and c.is_public == true)
        )
      end

    # Local posts
    local_query =
      from m in Message,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        where:
          is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            m.inserted_at > ^thirty_days_ago and
            m.sender_id != ^user_id,
        order_by: [desc: m.inserted_at],
        limit: ^limit

    local_query = from [m, c] in local_query, where: ^scope_and_visibility_filter

    local_query =
      if !Enum.empty?(all_blocked_ids) do
        from m in local_query, where: m.sender_id not in ^all_blocked_ids
      else
        local_query
      end

    # Federated posts
    federated_query =
      from m in Message,
        where:
          m.federated == true and
            m.visibility in ["public", "unlisted"] and
            is_nil(m.deleted_at) and
            m.inserted_at > ^thirty_days_ago,
        order_by: [desc: m.inserted_at],
        limit: ^limit

    local_posts =
      Repo.all(local_query)
      |> Repo.preload([
        :conversation,
        :link_preview,
        :hashtags,
        sender: [:profile],
        shared_message: [:link_preview, :remote_actor, sender: [:profile]]
      ])

    federated_posts =
      Repo.all(federated_query)
      |> Repo.preload([
        :remote_actor,
        :link_preview,
        :hashtags,
        shared_message: [:link_preview, :remote_actor, sender: [:profile]]
      ])

    (local_posts ++ federated_posts)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
    |> Enum.take(limit)
  end

  # Quick scoring for pre-filtering (cheap operations only)
  defp score_post_quick(post, user_profile) do
    score = 0

    # Following boost (cheap lookup)
    score =
      score +
        if post.federated do
          if post.remote_actor_id in user_profile.followed_remote_actors, do: 30, else: 0
        else
          if post.sender_id in user_profile.followed_users, do: 30, else: 0
        end

    # Engagement (already on post)
    total_engagement = (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)
    score = score + min(total_engagement, 20)

    # Media boost
    score = score + if (post.media_urls || []) != [], do: 10, else: 0

    # Recency
    score = score * recency_multiplier(post)

    score
  end

  # ==============================================================================
  # FULL SCORING (expensive operations)
  # ==============================================================================

  defp score_post_full(post, user_profile, user_id) do
    score = 0

    # 1. Creator Affinity with Dwell Time (45 points max)
    score = score + score_creator_affinity_with_dwell(post, user_profile)

    # 2. Content Similarity with Decay (30 points max)
    score = score + score_content_similarity_with_decay(post, user_profile)

    # 3. Collaborative Filtering (25 points max)
    score = score + score_collaborative(post, user_profile)

    # 4. Trending Boost (20 points max)
    score = score + score_trending(post)

    # 5. Media Content (15 points max)
    score = score + score_media_content(post)

    # 6. Domain Affinity (15 points max)
    score = score + score_domain_affinity(post, user_profile)

    # 7. Engagement Quality (10 points max)
    score = score + score_engagement_quality(post)

    # 8. Session Relevance (20 points max) - real-time adaptation
    score = score + score_session_relevance(post, user_profile)

    # 9. Creator Satisfaction (15 points max)
    score = score + score_creator_satisfaction(post, user_profile)

    # 10. Recency Multiplier
    score = score * recency_multiplier(post)

    # 11. Penalties (negative signals, already seen, etc.)
    score = apply_penalties(score, post, user_id, user_profile)

    score
  end

  # Creator Affinity with Dwell Time analysis
  defp score_creator_affinity_with_dwell(post, user_profile) do
    creator_key =
      if post.federated, do: {:remote, post.remote_actor_id}, else: {:local, post.sender_id}

    # Check if following
    following =
      if post.federated do
        post.remote_actor_id in user_profile.followed_remote_actors
      else
        post.sender_id in user_profile.followed_users
      end

    if following do
      # Following = strong signal
      40
    else
      # Use dwell time data
      avg_dwell = Map.get(user_profile.creator_dwell_times, creator_key, 0)

      cond do
        # 30+ seconds avg
        avg_dwell > @dwell_time_threshold_engaged ->
          35

        # 10+ seconds avg
        avg_dwell > @dwell_time_threshold_interested ->
          25

        # 3+ seconds avg
        avg_dwell > @dwell_time_threshold_glanced ->
          15

        !post.federated && Enum.any?(user_profile.liked_posts, &(&1.sender_id == post.sender_id)) ->
          20

        !post.federated && post.sender_id in user_profile.viewed_creators ->
          10

        # Small discovery boost for federated
        post.federated ->
          8

        true ->
          0
      end
    end
  end

  # Content Similarity with Interest Decay
  defp score_content_similarity_with_decay(post, user_profile) do
    # Hashtag overlap with decay weighting
    hashtag_score =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)

        # favorite_hashtags is now {hashtag, weight} tuples
        Enum.reduce(post_hashtags, 0, fn tag, acc ->
          weight = Map.get(user_profile.favorite_hashtags, tag, 0)
          # Scale weight to points
          acc + weight * 10
        end)
      else
        0
      end

    # High dwell time hashtags bonus
    high_dwell_bonus =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)

        matching_high_dwell =
          Enum.count(post_hashtags, &(&1 in user_profile.high_engagement_hashtags))

        matching_high_dwell * 5
      else
        0
      end

    # Category match
    category_score =
      if Map.get(post, :category) in user_profile.favorite_categories, do: 15, else: 0

    # Community match
    community_score =
      if post.conversation_id in user_profile.preferred_communities, do: 15, else: 0

    min(hashtag_score + high_dwell_bonus + category_score + community_score, 30)
  end

  # Collaborative Filtering
  defp score_collaborative(post, user_profile) do
    if post.id in user_profile.liked_by_followed, do: 25, else: 0
  end

  # Trending Score
  defp score_trending(post) do
    age_hours = NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :second) / 3600

    if age_hours < 24 do
      likes = post.like_count || 0
      replies = post.reply_count || 0
      boosts = post.share_count || 0

      engagement = likes + replies * 2 + boosts * 3
      velocity = engagement / max(age_hours, 1)

      cond do
        velocity > 50 -> 20
        velocity > 20 -> 18
        velocity > 10 -> 15
        velocity > 5 -> 12
        velocity > 2 -> 10
        velocity > 1 -> 5
        true -> 0
      end
    else
      0
    end
  end

  # Media Content Score
  defp score_media_content(post) do
    media_urls = post.media_urls || []

    cond do
      length(media_urls) >= 4 -> 15
      length(media_urls) >= 2 -> 12
      length(media_urls) == 1 -> 10
      post.link_preview && post.link_preview.image_url -> 5
      true -> 0
    end
  end

  # Domain Affinity
  defp score_domain_affinity(post, user_profile) do
    if post.federated && post.remote_actor do
      domain = post.remote_actor.domain
      if domain in user_profile.favorite_domains, do: 15, else: 5
    else
      0
    end
  end

  # Engagement Quality
  defp score_engagement_quality(post) do
    total = (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)

    cond do
      total >= 100 -> 10
      total >= 50 -> 8
      total >= 20 -> 6
      total >= 10 -> 4
      total >= 5 -> 2
      true -> 0
    end
  end

  # Session Relevance - real-time adaptation
  defp score_session_relevance(post, user_profile) do
    score = 0

    # Hashtag match with session likes
    score =
      score +
        if post.hashtags do
          post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)
          session_hashtags = user_profile.session_liked_hashtags
          matching = Enum.count(post_hashtags, &(&1 in session_hashtags))
          min(matching * 10, 15)
        else
          0
        end

    local_creators = user_profile.session_liked_local_creators
    remote_creators = user_profile.session_liked_remote_creators
    legacy_creators = user_profile.session_liked_creators

    creator_match =
      if post.federated do
        not is_nil(post.remote_actor_id) and
          (post.remote_actor_id in remote_creators or post.remote_actor_id in legacy_creators)
      else
        post.sender_id in local_creators or post.sender_id in legacy_creators
      end

    # Creator match with session engagement
    score = score + if creator_match, do: 10, else: 0

    # Boost if user is highly engaged this session
    score =
      if user_profile.session_engagement_rate > 0.3 do
        # 10% boost for engaged users
        score * 1.1
      else
        score
      end

    min(score, 20)
  end

  # Creator Satisfaction Score
  defp score_creator_satisfaction(post, user_profile) do
    creator_key =
      if post.federated, do: {:remote, post.remote_actor_id}, else: {:local, post.sender_id}

    satisfaction = Map.get(user_profile.creator_satisfaction, creator_key, 0.5)

    # Scale 0.0-1.0 satisfaction to 0-15 points
    round(satisfaction * 15)
  end

  # Recency Multiplier
  defp recency_multiplier(post) do
    hours_old = NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :second) / 3600

    cond do
      hours_old < 1 -> 1.15
      hours_old < 6 -> 1.1
      hours_old < 24 -> 1.0
      hours_old < 72 -> 0.9
      hours_old < 168 -> 0.7
      true -> 0.5
    end
  end

  # Apply Penalties including negative signals
  defp apply_penalties(score, post, user_id, user_profile) do
    # Own posts penalty
    score = if post.sender_id == user_id, do: score * 0.1, else: score

    # Already viewed penalty
    score = if post.id in user_profile.viewed_posts, do: score * 0.3, else: score

    # Session already viewed (even stronger penalty)
    score = if post.id in user_profile.session_viewed_posts, do: score * 0.1, else: score

    # Dismissed post penalty
    score = if post.id in user_profile.dismissed_posts, do: score * 0.05, else: score

    # Creator ignore rate penalty
    creator_key =
      if post.federated, do: {:remote, post.remote_actor_id}, else: {:local, post.sender_id}

    ignore_rate = Map.get(user_profile.creator_ignore_rates, creator_key, 0.0)
    # Up to 50% penalty
    score = score * (1.0 - ignore_rate * 0.5)

    # Dismissed hashtag penalty
    score =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)
        dismissed_overlap = Enum.count(post_hashtags, &(&1 in user_profile.dismissed_hashtags))
        if dismissed_overlap > 0, do: score * (1.0 - dismissed_overlap * 0.1), else: score
      else
        score
      end

    score
  end

  # ==============================================================================
  # EXPLORE/EXPLOIT BALANCE
  # ==============================================================================

  # Split scored posts into exploitation (personalized) and exploration (discovery)
  defp split_for_exploration(scored_posts, user_profile) do
    Enum.split_with(scored_posts, fn {post, _score} ->
      # Exploitation: content matching user's known interests
      matches_known_interest?(post, user_profile)
    end)
  end

  defp matches_known_interest?(post, user_profile) do
    # Check if post matches any strong user signal
    creator_match =
      if post.federated do
        post.remote_actor_id in user_profile.followed_remote_actors
      else
        post.sender_id in user_profile.followed_users or
          post.sender_id in user_profile.viewed_creators
      end

    hashtag_match =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)
        known_hashtags = Map.keys(user_profile.favorite_hashtags)
        Enum.any?(post_hashtags, &(&1 in known_hashtags))
      else
        false
      end

    domain_match =
      if post.federated && post.remote_actor do
        post.remote_actor.domain in user_profile.favorite_domains
      else
        false
      end

    creator_match or hashtag_match or domain_match
  end

  # Interleave exploration posts throughout the feed
  defp interleave_posts(main_posts, explore_posts) when explore_posts == [], do: main_posts

  defp interleave_posts(main_posts, explore_posts) do
    total = length(main_posts) + length(explore_posts)
    interval = max(div(total, length(explore_posts) + 1), 3)

    {result, remaining_explore} =
      Enum.reduce(Enum.with_index(main_posts), {[], explore_posts}, fn
        {post, idx}, {acc, [explore | rest]} when rem(idx + 1, interval) == 0 ->
          {acc ++ [post, explore], rest}

        {post, _idx}, {acc, explores} ->
          {acc ++ [post], explores}
      end)

    # Append any remaining exploration posts
    result ++ remaining_explore
  end

  # Diversify feed to prevent monotony
  defp diversify_feed(posts) do
    posts
    |> Enum.reduce({[], nil, 0}, fn post, {acc, last_creator, consecutive} ->
      creator_key =
        if post.federated, do: {:remote, post.remote_actor_id}, else: {:local, post.sender_id}

      if creator_key == last_creator && consecutive >= @max_consecutive_same_creator do
        {acc, last_creator, consecutive}
      else
        new_consecutive = if creator_key == last_creator, do: consecutive + 1, else: 1
        {acc ++ [post], creator_key, new_consecutive}
      end
    end)
    |> elem(0)
  end

  # ==============================================================================
  # DATA FETCHING HELPERS
  # ==============================================================================

  defp get_user_liked_posts(user_id) do
    from(l in Social.PostLike,
      where: l.user_id == ^user_id,
      join: m in Message,
      on: m.id == l.message_id,
      select: m
    )
    |> Repo.all()
    |> Repo.preload([:hashtags, sender: [:profile]])
  end

  defp get_followed_user_ids(user_id) do
    from(f in Elektrine.Profiles.Follow,
      where: f.follower_id == ^user_id and is_nil(f.remote_actor_id),
      select: f.followed_id
    )
    |> Repo.all()
  end

  defp get_followed_remote_actor_ids(user_id) do
    from(f in Elektrine.Profiles.Follow,
      where: f.follower_id == ^user_id and not is_nil(f.remote_actor_id) and f.pending == false,
      select: f.remote_actor_id
    )
    |> Repo.all()
  end

  # Interest Decay: Hashtags weighted by recency using exponential decay
  defp get_user_favorite_hashtags_with_decay(user_id) do
    # Get hashtags with recency-weighted scores
    results =
      from(l in Social.PostLike,
        where: l.user_id == ^user_id,
        join: m in Message,
        on: m.id == l.message_id,
        join: h in assoc(m, :hashtags),
        group_by: h.normalized_name,
        select: {
          h.normalized_name,
          sum(
            fragment(
              "EXP(-? * EXTRACT(EPOCH FROM (NOW() - ?)) / 86400)",
              @interest_decay_rate,
              l.created_at
            )
          )
        },
        order_by: [desc: 2],
        limit: 30
      )
      |> Repo.all()

    # Normalize weights to 0-1 range
    max_weight = results |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)

    results
    |> Enum.map(fn {hashtag, weight} -> {hashtag, weight / max_weight} end)
    |> Map.new()
  end

  defp get_user_favorite_categories(_user_id), do: []

  defp get_user_communities(user_id) do
    Elektrine.Messaging.list_conversations(user_id)
    |> Enum.filter(&(&1.type == "community"))
    |> Enum.map(& &1.id)
  end

  defp analyze_engagement_types(user_id) do
    from(l in Social.PostLike,
      where: l.user_id == ^user_id,
      join: m in Message,
      on: m.id == l.message_id,
      group_by: m.post_type,
      select: {m.post_type, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp get_user_viewed_posts(user_id) do
    seven_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 24 * 60 * 60)

    from(v in PostView,
      where: v.user_id == ^user_id and v.inserted_at > ^seven_days_ago,
      select: v.message_id
    )
    |> Repo.all()
  end

  defp get_viewed_creator_ids(user_id) do
    from(v in PostView,
      where: v.user_id == ^user_id,
      join: m in Message,
      on: m.id == v.message_id,
      group_by: m.sender_id,
      having: count(m.id) >= 3,
      select: m.sender_id
    )
    |> Repo.all()
  end

  defp get_user_favorite_domains(user_id) do
    from(l in Social.PostLike,
      where: l.user_id == ^user_id,
      join: m in Message,
      on: m.id == l.message_id,
      join: a in Elektrine.ActivityPub.Actor,
      on: a.id == m.remote_actor_id,
      where: m.federated == true,
      group_by: a.domain,
      select: a.domain,
      order_by: [desc: count(a.id)],
      limit: 20
    )
    |> Repo.all()
  end

  defp get_posts_liked_by_followed(user_id) do
    followed_ids = get_followed_user_ids(user_id)

    if Enum.empty?(followed_ids) do
      []
    else
      seven_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7, :day)

      from(l in Social.PostLike,
        where: l.user_id in ^followed_ids and l.created_at > ^seven_days_ago,
        select: l.message_id,
        distinct: true
      )
      |> Repo.all()
    end
  end

  # ==============================================================================
  # DWELL TIME DATA
  # ==============================================================================

  defp get_creator_avg_dwell_times(user_id) do
    # Get average dwell time per creator (local)
    local_results =
      from(v in PostView,
        where: v.user_id == ^user_id and not is_nil(v.dwell_time_ms),
        join: m in Message,
        on: m.id == v.message_id,
        where: is_nil(m.remote_actor_id),
        group_by: m.sender_id,
        having: count(v.id) >= 2,
        select: {m.sender_id, avg(v.dwell_time_ms)}
      )
      |> Repo.all()
      |> Enum.map(fn {sender_id, avg} -> {{:local, sender_id}, decimal_to_int(avg)} end)

    # Get average dwell time per remote actor
    remote_results =
      from(v in PostView,
        where: v.user_id == ^user_id and not is_nil(v.dwell_time_ms),
        join: m in Message,
        on: m.id == v.message_id,
        where: not is_nil(m.remote_actor_id),
        group_by: m.remote_actor_id,
        having: count(v.id) >= 2,
        select: {m.remote_actor_id, avg(v.dwell_time_ms)}
      )
      |> Repo.all()
      |> Enum.map(fn {actor_id, avg} -> {{:remote, actor_id}, decimal_to_int(avg)} end)

    Map.new(local_results ++ remote_results)
  end

  defp get_high_dwell_hashtags(user_id) do
    # Hashtags where user spends significant time
    from(v in PostView,
      where: v.user_id == ^user_id and v.dwell_time_ms > @dwell_time_threshold_interested,
      join: m in Message,
      on: m.id == v.message_id,
      join: h in assoc(m, :hashtags),
      group_by: h.normalized_name,
      having: count(v.id) >= 3,
      select: h.normalized_name
    )
    |> Repo.all()
  end

  # ==============================================================================
  # NEGATIVE SIGNALS
  # ==============================================================================

  defp get_dismissed_post_ids(user_id) do
    from(d in PostDismissal,
      where: d.user_id == ^user_id,
      select: d.message_id
    )
    |> Repo.all()
  end

  defp get_creator_ignore_rates(user_id) do
    # Calculate ignore rate: dismissals / (views + dismissals) per creator
    # Get view counts per local creator
    view_counts =
      from(v in PostView,
        where: v.user_id == ^user_id,
        join: m in Message,
        on: m.id == v.message_id,
        group_by: [m.sender_id, m.remote_actor_id],
        select: {m.sender_id, m.remote_actor_id, count(v.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {sender_id, remote_actor_id, count} ->
        key = if remote_actor_id, do: {:remote, remote_actor_id}, else: {:local, sender_id}
        {key, count}
      end)
      |> Map.new()

    # Get dismissal counts per creator
    dismissal_counts =
      from(d in PostDismissal,
        where: d.user_id == ^user_id,
        join: m in Message,
        on: m.id == d.message_id,
        group_by: [m.sender_id, m.remote_actor_id],
        select: {m.sender_id, m.remote_actor_id, count(d.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {sender_id, remote_actor_id, count} ->
        key = if remote_actor_id, do: {:remote, remote_actor_id}, else: {:local, sender_id}
        {key, count}
      end)
      |> Map.new()

    # Calculate ignore rates
    all_creators =
      MapSet.union(MapSet.new(Map.keys(view_counts)), MapSet.new(Map.keys(dismissal_counts)))

    all_creators
    |> Enum.map(fn creator_key ->
      views = Map.get(view_counts, creator_key, 0)
      dismissals = Map.get(dismissal_counts, creator_key, 0)
      total = views + dismissals
      rate = if total > 0, do: dismissals / total, else: 0.0
      {creator_key, rate}
    end)
    |> Map.new()
  end

  defp get_frequently_dismissed_hashtags(user_id) do
    from(d in PostDismissal,
      where: d.user_id == ^user_id,
      join: m in Message,
      on: m.id == d.message_id,
      join: h in assoc(m, :hashtags),
      group_by: h.normalized_name,
      having: count(d.id) >= 3,
      select: h.normalized_name
    )
    |> Repo.all()
  end

  # ==============================================================================
  # SATISFACTION DATA
  # ==============================================================================

  defp get_creator_satisfaction_scores(user_id) do
    from(s in CreatorSatisfaction,
      where: s.user_id == ^user_id,
      select: s
    )
    |> Repo.all()
    |> Enum.map(fn sat ->
      key =
        if sat.remote_actor_id, do: {:remote, sat.remote_actor_id}, else: {:local, sat.creator_id}

      score = CreatorSatisfaction.satisfaction_score(sat)
      {key, score}
    end)
    |> Map.new()
  end

  # ==============================================================================
  # PUBLIC API FOR TRACKING
  # ==============================================================================

  @doc """
  Records a post dismissal (negative signal).
  """
  def record_dismissal(user_id, message_id, type, dwell_time_ms \\ nil) do
    %PostDismissal{}
    |> PostDismissal.changeset(%{
      user_id: user_id,
      message_id: message_id,
      dismissal_type: type,
      dwell_time_ms: dwell_time_ms
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Updates or creates a post view with dwell time data.
  """
  def record_view_with_dwell(user_id, message_id, attrs \\ %{}) do
    # Use limit(1) to handle any duplicate records in the database
    existing =
      PostView
      |> where([pv], pv.user_id == ^user_id and pv.message_id == ^message_id)
      |> limit(1)
      |> Repo.one()

    case existing do
      nil ->
        %PostView{}
        |> PostView.changeset(Map.merge(%{user_id: user_id, message_id: message_id}, attrs))
        |> Repo.insert(on_conflict: :nothing)

      existing ->
        # Update dwell time (accumulate if already exists)
        new_dwell = (existing.dwell_time_ms || 0) + (attrs[:dwell_time_ms] || 0)
        new_scroll = max(existing.scroll_depth || 0, attrs[:scroll_depth] || 0)
        new_expanded = existing.expanded || attrs[:expanded] || false

        existing
        |> PostView.update_dwell_changeset(%{
          dwell_time_ms: new_dwell,
          scroll_depth: new_scroll,
          expanded: new_expanded
        })
        |> Repo.update()
    end
  end

  # Convert Decimal (from PostgreSQL avg()) to integer
  defp decimal_to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp decimal_to_int(n) when is_number(n), do: trunc(n)
  defp decimal_to_int(nil), do: 0
end
