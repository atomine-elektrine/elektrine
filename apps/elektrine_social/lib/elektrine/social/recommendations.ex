defmodule Elektrine.Social.Recommendations do
  @moduledoc "Advanced content recommendation engine with sophisticated ranking algorithms.\n\nFeatures:\n- Dwell time analysis (time spent = interest signal)\n- Negative signals (dismissals, scroll-past detection)\n- Session-aware adaptation (real-time preference learning)\n- Explore/exploit balance (discovery vs. known interests)\n- Interest decay (recent interests weighted more)\n- Two-stage retrieval (fast candidate generation + expensive ranking)\n- Satisfaction scoring (quality over clickbait)\n- Collaborative filtering (what similar users like)\n- Trending detection (engagement velocity)\n- Diversity enforcement (prevent echo chambers)\n"
  import Ecto.Query
  alias Elektrine.{Messaging.Message, Social}
  alias Elektrine.Repo
  alias Elektrine.Social.{CreatorSatisfaction, PostDismissal, PostView, Views}
  @min_score_threshold 10
  @exploration_ratio 0.15
  @interest_decay_rate 0.1
  @max_consecutive_same_creator 3
  @dwell_time_threshold_engaged 30_000
  @dwell_time_threshold_interested 10_000
  @dwell_time_threshold_glanced 3000
  @doc "Gets personalized recommendation feed for a user.\n\n## Options\n- `:limit` - Maximum posts to return (default: 50)\n- `:session_context` - Map with session engagement data for real-time adaptation\n"
  def get_for_you_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    filter = Keyword.get(opts, :filter, "all")
    session_context = Keyword.get(opts, :session_context, %{})

    cond do
      filter == "my_posts" ->
        get_recommended_own_posts(user_id, limit)

      recommendations_enabled?() ->
        user_profile = build_user_profile(user_id, session_context)

        recommended_posts =
          user_id
          |> recommend_posts(expanded_limit(filter, limit), user_profile)
          |> then(&filter_posts_for_feed(filter, &1))
          |> Enum.take(limit)

        if recommended_posts == [] do
          fallback_posts_for_filter(user_id, filter, limit)
        else
          recommended_posts
        end

      true ->
        fallback_posts_for_filter(user_id, filter, limit)
    end
  end

  defp recommend_posts(user_id, limit, user_profile) do
    candidates = get_candidate_posts_fast(user_id, limit * 10)

    pre_scored =
      candidates
      |> Enum.map(fn post -> {post, score_post_quick(post, user_profile)} end)
      |> Enum.sort_by(fn {_post, score} -> score end, :desc)
      |> Enum.take(limit * 3)

    ranked_scored =
      pre_scored
      |> Enum.map(fn {post, _quick_score} ->
        {post, score_post_full(post, user_profile, user_id)}
      end)
      |> Enum.sort_by(fn {_post, score} -> score end, :desc)

    fully_scored =
      ranked_scored
      |> Enum.filter(fn {post, score} ->
        recommended_for_feed?(post, score, user_profile)
      end)

    fully_scored =
      if fully_scored == [] do
        ranked_scored
      else
        fully_scored
      end

    {exploit_posts, explore_candidates} = split_for_exploration(fully_scored, user_profile)

    main_feed =
      exploit_posts
      |> Enum.take(ceil(limit * (1 - @exploration_ratio)))
      |> Enum.map(fn {post, _score} -> post end)

    explore_posts = select_exploration_posts(explore_candidates, limit, user_profile)

    main_feed
    |> interleave_posts(explore_posts)
    |> diversify_feed()
  end

  defp expanded_limit("all", limit), do: limit
  defp expanded_limit(_, limit), do: max(limit * 4, limit + 20)

  defp filter_posts_for_feed("timeline", posts) do
    Enum.filter(posts, &timeline_feed_post?/1)
  end

  defp filter_posts_for_feed("gallery", posts) do
    Enum.filter(posts, &gallery_feed_post?/1)
  end

  defp filter_posts_for_feed("discussions", posts) do
    Enum.filter(posts, &discussion_feed_post?/1)
  end

  defp filter_posts_for_feed(_filter, posts), do: posts

  defp timeline_feed_post?(post) do
    !gallery_feed_post?(post) && !discussion_feed_post?(post)
  end

  defp gallery_feed_post?(post) do
    post_type = Map.get(post, :post_type)
    media_urls = Map.get(post, :media_urls) || []

    post_type == "gallery" or media_urls != []
  end

  defp discussion_feed_post?(post) do
    conversation_type =
      post
      |> Map.get(:conversation)
      |> case do
        conversation when is_map(conversation) -> Map.get(conversation, :type)
        _ -> nil
      end

    community_actor_uri = get_in(Map.get(post, :media_metadata) || %{}, ["community_actor_uri"])

    Map.get(post, :post_type) == "discussion" or conversation_type == "community" or
      is_binary(community_actor_uri)
  end

  defp fallback_posts_for_filter(user_id, "timeline", limit) do
    Social.get_public_timeline(user_id: user_id, limit: expanded_limit("timeline", limit))
    |> then(&filter_posts_for_feed("timeline", &1))
    |> Enum.take(limit)
  end

  defp fallback_posts_for_filter(user_id, "gallery", limit) do
    Social.get_public_timeline(user_id: user_id, limit: expanded_limit("gallery", limit))
    |> then(&filter_posts_for_feed("gallery", &1))
    |> Enum.take(limit)
  end

  defp fallback_posts_for_filter(user_id, "discussions", limit) do
    Social.get_public_community_posts(user_id: user_id, limit: limit)
  end

  defp fallback_posts_for_filter(user_id, "my_posts", limit) do
    get_recommended_own_posts(user_id, limit)
  end

  defp fallback_posts_for_filter(user_id, _filter, limit) do
    Social.get_public_timeline(user_id: user_id, limit: limit)
  end

  defp get_recommended_own_posts(user_id, limit) do
    from(m in Message,
      left_join: c in Elektrine.Messaging.Conversation,
      on: c.id == m.conversation_id,
      where:
        m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at),
      order_by: [
        desc:
          fragment(
            "(COALESCE(?, 0) * 4) + (COALESCE(?, 0) * 3) + (COALESCE(?, 0) * 2) + EXTRACT(EPOCH FROM ?) / 86400.0",
            m.reply_count,
            m.share_count,
            m.like_count,
            m.inserted_at
          ),
        desc: m.inserted_at,
        desc: m.id
      ],
      limit: ^limit,
      preload: ^own_post_preloads()
    )
    |> Repo.all()
  end

  defp own_post_preloads do
    [
      :conversation,
      :link_preview,
      :hashtags,
      sender: [:profile],
      shared_message: [:link_preview, :remote_actor, sender: [:profile]]
    ]
  end

  defp recommendations_enabled? do
    Application.get_env(:elektrine, :recommendations_enabled, true)
  end

  defp qualifies_for_feed?(post, user_profile) do
    cond do
      post.sender_id in user_profile.followed_users -> true
      post.federated && post.remote_actor_id in user_profile.followed_remote_actors -> true
      (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0) >= 5 -> true
      (post.media_urls || []) != [] && (post.like_count || 0) >= 2 -> true
      true -> false
    end
  end

  defp recommended_for_feed?(post, score, user_profile) do
    qualifies_for_feed?(post, user_profile) or exploratory_candidate?(post, score)
  end

  defp exploratory_candidate?(post, score) do
    score >= @min_score_threshold and
      ((post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0) >= 2 or
         (post.media_urls || []) != [])
  end

  defp build_user_profile(user_id, session_context) do
    %{
      liked_posts: get_user_liked_posts(user_id),
      viewed_posts: get_user_viewed_posts(user_id),
      followed_users: get_followed_user_ids(user_id),
      followed_remote_actors: get_followed_remote_actor_ids(user_id),
      favorite_hashtags: get_user_favorite_hashtags_with_decay(user_id),
      favorite_categories: get_user_favorite_categories(user_id),
      preferred_communities: get_user_communities(user_id),
      favorite_domains: get_user_favorite_domains(user_id),
      engagement_types: analyze_engagement_types(user_id),
      viewed_creators: get_viewed_creator_ids(user_id),
      liked_by_followed: get_posts_liked_by_followed(user_id),
      creator_dwell_times: get_creator_avg_dwell_times(user_id),
      high_engagement_hashtags: get_high_dwell_hashtags(user_id),
      dismissed_posts: get_dismissed_post_ids(user_id),
      creator_ignore_rates: get_creator_ignore_rates(user_id),
      dismissed_hashtags: get_frequently_dismissed_hashtags(user_id),
      creator_satisfaction: get_creator_satisfaction_scores(user_id),
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
      session_viewed_posts: Map.get(session_context, :viewed_posts, []),
      session_dismissed_posts: Map.get(session_context, :dismissed_posts, [])
    }
  end

  defp get_candidate_posts_fast(user_id, limit) do
    blocked_user_ids = Elektrine.Accounts.list_blocked_users(user_id) |> Enum.map(& &1.id)
    blocked_by_user_ids = Elektrine.Accounts.list_users_who_blocked(user_id) |> Enum.map(& &1.id)
    followed_user_ids = get_followed_user_ids(user_id)
    followed_remote_actor_ids = get_followed_remote_actor_ids(user_id)
    all_blocked_ids = (blocked_user_ids ++ blocked_by_user_ids) |> Enum.uniq()
    thirty_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-30, :day)
    seven_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7, :day)
    three_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3, :day)
    recent_pool_limit = candidate_pool_limit(limit, 0.5, 24)
    interest_pool_limit = candidate_pool_limit(limit, 0.3, 12)
    discovery_pool_limit = candidate_pool_limit(limit, 0.2, 8)

    scope_and_visibility_filter =
      if Enum.empty?(followed_user_ids) do
        dynamic(
          [m, c],
          (c.type == "timeline" and m.post_type in ["post", "gallery"] and
             m.visibility == "public") or
            (c.type == "community" and m.post_type == "discussion" and c.is_public == true)
        )
      else
        dynamic(
          [m, c],
          (c.type == "timeline" and m.post_type in ["post", "gallery"] and
             (m.visibility == "public" or
                (m.visibility == "followers" and m.sender_id in ^followed_user_ids))) or
            (c.type == "community" and m.post_type == "discussion" and c.is_public == true)
        )
      end

    local_base_query =
      from(m in Message,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        where:
          is_nil(m.deleted_at) and (m.approval_status == "approved" or is_nil(m.approval_status)) and
            m.inserted_at > ^thirty_days_ago and m.sender_id != ^user_id
      )

    local_base_query = from([m, c] in local_base_query, where: ^scope_and_visibility_filter)

    local_base_query =
      if Enum.empty?(all_blocked_ids) do
        local_base_query
      else
        from(m in local_base_query, where: m.sender_id not in ^all_blocked_ids)
      end

    federated_base_query =
      from(m in Message,
        where:
          m.federated == true and m.visibility in ["public", "unlisted"] and is_nil(m.deleted_at) and
            m.inserted_at > ^thirty_days_ago
      )

    federated_base_query =
      if Enum.empty?(all_blocked_ids) do
        federated_base_query
      else
        from(m in federated_base_query,
          where: is_nil(m.sender_id) or m.sender_id not in ^all_blocked_ids
        )
      end

    local_preloads = [
      :conversation,
      :link_preview,
      :hashtags,
      sender: [:profile],
      shared_message: [:link_preview, :remote_actor, sender: [:profile]]
    ]

    federated_preloads = [
      :remote_actor,
      :link_preview,
      :hashtags,
      shared_message: [:link_preview, :remote_actor, sender: [:profile]]
    ]

    local_recent_query =
      from([m, _c] in local_base_query,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^recent_pool_limit
      )

    local_trending_query =
      from([m, _c] in local_base_query,
        where: m.inserted_at > ^seven_days_ago,
        order_by: [
          desc:
            fragment(
              "COALESCE(?, 0) + (COALESCE(?, 0) * 2) + (COALESCE(?, 0) * 3)",
              m.like_count,
              m.reply_count,
              m.share_count
            ),
          desc: m.inserted_at
        ],
        limit: ^recent_pool_limit
      )

    local_discussion_query =
      from([m, c] in local_base_query,
        where: c.type == "community" and m.post_type == "discussion",
        order_by: [desc: m.reply_count, desc: m.like_count, desc: m.inserted_at],
        limit: ^interest_pool_limit
      )

    local_media_query =
      from([m, _c] in local_base_query,
        where: fragment("COALESCE(array_length(?, 1), 0) > 0", m.media_urls),
        order_by: [desc: m.inserted_at, desc: m.like_count],
        limit: ^interest_pool_limit
      )

    local_underexposed_query =
      from([m, _c] in local_base_query,
        where:
          m.inserted_at > ^three_days_ago and
            fragment(
              "COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) <= 6",
              m.like_count,
              m.reply_count,
              m.share_count
            ),
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^discovery_pool_limit
      )

    local_followed_query =
      if Enum.empty?(followed_user_ids) do
        nil
      else
        from([m, _c] in local_base_query,
          where: m.sender_id in ^followed_user_ids,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^interest_pool_limit
        )
      end

    federated_recent_query =
      from(m in federated_base_query,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^recent_pool_limit
      )

    federated_trending_query =
      from(m in federated_base_query,
        where: m.inserted_at > ^seven_days_ago,
        order_by: [
          desc:
            fragment(
              "COALESCE(?, 0) + (COALESCE(?, 0) * 2) + (COALESCE(?, 0) * 3)",
              m.like_count,
              m.reply_count,
              m.share_count
            ),
          desc: m.inserted_at
        ],
        limit: ^interest_pool_limit
      )

    federated_underexposed_query =
      from(m in federated_base_query,
        where:
          m.inserted_at > ^three_days_ago and
            fragment(
              "COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) <= 6",
              m.like_count,
              m.reply_count,
              m.share_count
            ),
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^discovery_pool_limit
      )

    federated_followed_query =
      if Enum.empty?(followed_remote_actor_ids) do
        nil
      else
        from(m in federated_base_query,
          where: m.remote_actor_id in ^followed_remote_actor_ids,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^interest_pool_limit
        )
      end

    local_posts =
      [
        local_followed_query,
        local_trending_query,
        local_media_query,
        local_discussion_query,
        local_underexposed_query,
        local_recent_query
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&load_candidate_pool(&1, local_preloads))

    federated_posts =
      [
        federated_followed_query,
        federated_trending_query,
        federated_underexposed_query,
        federated_recent_query
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&load_candidate_pool(&1, federated_preloads))

    (local_posts ++ federated_posts)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(
      fn post ->
        {
          if(post.federated, do: 0, else: 1),
          normalize_inserted_at(post.inserted_at),
          post.id
        }
      end,
      :desc
    )
    |> Enum.take(limit)
  end

  defp load_candidate_pool(query, preloads) do
    query
    |> Repo.all()
    |> Repo.preload(preloads)
  end

  defp candidate_pool_limit(limit, ratio, min_size) do
    max(trunc(limit * ratio), min_size)
  end

  defp score_post_quick(post, user_profile) do
    score = 0

    score =
      score +
        if post.federated do
          if post.remote_actor_id in user_profile.followed_remote_actors do
            30
          else
            0
          end
        else
          if post.sender_id in user_profile.followed_users do
            30
          else
            0
          end
        end

    total_engagement = (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)
    score = score + min(total_engagement, 20)

    score =
      score +
        if (post.media_urls || []) != [] do
          10
        else
          0
        end

    score = score * recency_multiplier(post)
    score
  end

  defp score_post_full(post, user_profile, user_id) do
    score = 0
    score = score + score_creator_affinity_with_dwell(post, user_profile)
    score = score + score_content_similarity_with_decay(post, user_profile)
    score = score + score_collaborative(post, user_profile)
    score = score + score_trending(post)
    score = score + score_media_content(post)
    score = score + score_novelty(post, user_profile)
    score = score + score_retention_fit(post)
    score = score + score_domain_affinity(post, user_profile)
    score = score + score_engagement_quality(post)
    score = score + score_session_relevance(post, user_profile)
    score = score + score_creator_satisfaction(post, user_profile)
    score = score * recency_multiplier(post)
    score = apply_penalties(score, post, user_id, user_profile)
    score
  end

  defp score_creator_affinity_with_dwell(post, user_profile) do
    creator_key =
      if post.federated do
        {:remote, post.remote_actor_id}
      else
        {:local, post.sender_id}
      end

    following =
      if post.federated do
        post.remote_actor_id in user_profile.followed_remote_actors
      else
        post.sender_id in user_profile.followed_users
      end

    if following do
      40
    else
      avg_dwell = Map.get(user_profile.creator_dwell_times, creator_key, 0)

      cond do
        avg_dwell > @dwell_time_threshold_engaged ->
          35

        avg_dwell > @dwell_time_threshold_interested ->
          25

        avg_dwell > @dwell_time_threshold_glanced ->
          15

        !post.federated && Enum.any?(user_profile.liked_posts, &(&1.sender_id == post.sender_id)) ->
          20

        !post.federated && post.sender_id in user_profile.viewed_creators ->
          10

        post.federated ->
          8

        true ->
          0
      end
    end
  end

  defp score_content_similarity_with_decay(post, user_profile) do
    hashtag_score =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)

        Enum.reduce(post_hashtags, 0, fn tag, acc ->
          weight = Map.get(user_profile.favorite_hashtags, tag, 0)
          acc + weight * 10
        end)
      else
        0
      end

    high_dwell_bonus =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)

        matching_high_dwell =
          Enum.count(post_hashtags, &(&1 in user_profile.high_engagement_hashtags))

        matching_high_dwell * 5
      else
        0
      end

    category_score =
      post
      |> post_interest_categories()
      |> Enum.count(&(&1 in user_profile.favorite_categories))
      |> Kernel.*(8)
      |> min(15)

    community_score =
      if post.conversation_id in user_profile.preferred_communities do
        15
      else
        0
      end

    min(hashtag_score + high_dwell_bonus + category_score + community_score, 30)
  end

  defp score_novelty(post, user_profile) do
    creator_known =
      if post.federated do
        post.remote_actor_id in user_profile.followed_remote_actors
      else
        post.sender_id in user_profile.followed_users or
          post.sender_id in user_profile.viewed_creators
      end

    post_has_been_seen =
      post.id in user_profile.viewed_posts or post.id in user_profile.session_viewed_posts

    total_engagement = (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)
    hours_old = NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :second) / 3600

    cond do
      creator_known or post_has_been_seen ->
        0

      hours_old < 18 and total_engagement <= 8 and total_engagement >= 1 ->
        12

      hours_old < 36 and total_engagement <= 15 ->
        8

      hours_old < 72 ->
        4

      true ->
        0
    end
  end

  defp score_retention_fit(post) do
    content = String.trim(post.content || "")
    content_length = String.length(content)
    media_count = length(post.media_urls || [])

    cond do
      media_count > 0 and content_length <= 320 ->
        8

      post.post_type == "discussion" and (post.reply_count || 0) >= 2 ->
        6

      media_count > 0 ->
        4

      content_length in 1..220 ->
        3

      content_length > 1200 and media_count == 0 ->
        -4

      true ->
        0
    end
  end

  defp score_collaborative(post, user_profile) do
    if post.id in user_profile.liked_by_followed do
      25
    else
      0
    end
  end

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

  defp score_domain_affinity(post, user_profile) do
    if post.federated && post.remote_actor do
      domain = post.remote_actor.domain

      if domain in user_profile.favorite_domains do
        15
      else
        5
      end
    else
      0
    end
  end

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

  defp score_session_relevance(post, user_profile) do
    score = 0

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

    score =
      score +
        if creator_match do
          10
        else
          0
        end

    score =
      if user_profile.session_engagement_rate > 0.3 do
        score * 1.1
      else
        score
      end

    min(score, 20)
  end

  defp score_creator_satisfaction(post, user_profile) do
    creator_key =
      if post.federated do
        {:remote, post.remote_actor_id}
      else
        {:local, post.sender_id}
      end

    satisfaction = Map.get(user_profile.creator_satisfaction, creator_key, 0.5)
    round(satisfaction * 15)
  end

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

  defp apply_penalties(score, post, user_id, user_profile) do
    score =
      if post.sender_id == user_id do
        score * 0.1
      else
        score
      end

    score =
      if post.id in user_profile.viewed_posts do
        score * 0.3
      else
        score
      end

    score =
      if post.id in user_profile.session_viewed_posts do
        score * 0.1
      else
        score
      end

    score =
      if post.id in user_profile.session_dismissed_posts do
        score * 0.01
      else
        score
      end

    score =
      if post.id in user_profile.dismissed_posts do
        score * 0.05
      else
        score
      end

    creator_key =
      if post.federated do
        {:remote, post.remote_actor_id}
      else
        {:local, post.sender_id}
      end

    ignore_rate = Map.get(user_profile.creator_ignore_rates, creator_key, 0.0)
    score = score * (1.0 - ignore_rate * 0.5)

    score =
      if post.hashtags do
        post_hashtags = Enum.map(post.hashtags, & &1.normalized_name)
        dismissed_overlap = Enum.count(post_hashtags, &(&1 in user_profile.dismissed_hashtags))

        if dismissed_overlap > 0 do
          score * (1.0 - dismissed_overlap * 0.1)
        else
          score
        end
      else
        score
      end

    score
  end

  defp split_for_exploration(scored_posts, user_profile) do
    Enum.split_with(scored_posts, fn {post, _score} ->
      matches_known_interest?(post, user_profile)
    end)
  end

  defp select_exploration_posts(explore_candidates, limit, user_profile) do
    exploration_count = ceil(limit * @exploration_ratio)

    explore_candidates
    |> Enum.sort_by(&exploration_priority(&1, user_profile), :desc)
    |> Enum.take(exploration_count)
    |> Enum.map(fn {post, _score} -> post end)
  end

  defp exploration_priority({post, score}, user_profile) do
    freshness_bonus =
      case NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :hour) do
        hours when hours < 12 -> 8
        hours when hours < 24 -> 5
        hours when hours < 72 -> 2
        _ -> 0
      end

    novelty_bonus = score_novelty(post, user_profile)
    retention_bonus = max(score_retention_fit(post), 0)
    total_engagement = (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)
    underexposed_bonus = if total_engagement <= 8, do: 6, else: 0

    score + freshness_bonus + novelty_bonus + retention_bonus + underexposed_bonus
  end

  defp matches_known_interest?(post, user_profile) do
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

  defp interleave_posts(main_posts, explore_posts) when explore_posts == [] do
    main_posts
  end

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

    result ++ remaining_explore
  end

  defp diversify_feed(posts) do
    posts
    |> do_diversify_feed([], nil, 0)
    |> Enum.reverse()
  end

  defp do_diversify_feed([], acc, _last_creator, _consecutive), do: acc

  defp do_diversify_feed(posts, acc, last_creator, consecutive) do
    {next_post, remaining_posts} = pick_next_diverse_post(posts, last_creator, consecutive)
    creator = post_creator_key(next_post)

    new_consecutive =
      if creator == last_creator do
        consecutive + 1
      else
        1
      end

    do_diversify_feed(remaining_posts, [next_post | acc], creator, new_consecutive)
  end

  defp pick_next_diverse_post([post | rest], last_creator, consecutive) do
    if post_creator_key(post) != last_creator or consecutive < @max_consecutive_same_creator do
      {post, rest}
    else
      case Enum.find_index(rest, fn candidate -> post_creator_key(candidate) != last_creator end) do
        nil ->
          {post, rest}

        index ->
          replacement = Enum.at(rest, index)
          {replacement, [post | List.delete_at(rest, index)]}
      end
    end
  end

  defp post_creator_key(post) do
    if post.federated do
      {:remote, post.remote_actor_id}
    else
      {:local, post.sender_id}
    end
  end

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

  defp get_user_favorite_hashtags_with_decay(user_id) do
    results =
      from(l in Social.PostLike,
        where: l.user_id == ^user_id,
        join: m in Message,
        on: m.id == l.message_id,
        join: h in assoc(m, :hashtags),
        group_by: h.normalized_name,
        select:
          {h.normalized_name,
           sum(
             fragment(
               "EXP(-? * EXTRACT(EPOCH FROM (NOW() - ?)) / 86_400)",
               @interest_decay_rate,
               l.created_at
             )
           )},
        order_by: [desc: 2],
        limit: 30
      )
      |> Repo.all()

    max_weight = results |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
    results |> Enum.map(fn {hashtag, weight} -> {hashtag, weight / max_weight} end) |> Map.new()
  end

  defp get_user_favorite_categories(user_id) do
    post_type_categories =
      from(l in Social.PostLike,
        where: l.user_id == ^user_id,
        join: m in Message,
        on: m.id == l.message_id,
        where: not is_nil(m.post_type),
        group_by: m.post_type,
        order_by: [desc: count(m.id)],
        limit: 5,
        select: m.post_type
      )
      |> Repo.all()

    community_categories =
      from(l in Social.PostLike,
        where: l.user_id == ^user_id,
        join: m in Message,
        on: m.id == l.message_id,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        where: not is_nil(c.community_category),
        group_by: c.community_category,
        order_by: [desc: count(c.id)],
        limit: 5,
        select: c.community_category
      )
      |> Repo.all()

    (post_type_categories ++ community_categories)
    |> Enum.filter(&Elektrine.Strings.present?/1)
    |> Enum.uniq()
  end

  defp post_interest_categories(post) do
    community_category =
      case Map.get(post, :conversation) do
        %{community_category: category} when is_binary(category) ->
          Elektrine.Strings.present(category)

        _ ->
          nil
      end

    [Map.get(post, :post_type), community_category]
    |> Enum.filter(&Elektrine.Strings.present?/1)
  end

  defp normalize_inserted_at(%NaiveDateTime{} = inserted_at), do: inserted_at
  defp normalize_inserted_at(%DateTime{} = inserted_at), do: DateTime.to_naive(inserted_at)
  defp normalize_inserted_at(_), do: ~N[1970-01-01 00:00:00]

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

  defp get_creator_avg_dwell_times(user_id) do
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

  defp get_dismissed_post_ids(user_id) do
    from(d in PostDismissal, where: d.user_id == ^user_id, select: d.message_id) |> Repo.all()
  end

  defp get_creator_ignore_rates(user_id) do
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
        key =
          if remote_actor_id do
            {:remote, remote_actor_id}
          else
            {:local, sender_id}
          end

        {key, count}
      end)
      |> Map.new()

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
        key =
          if remote_actor_id do
            {:remote, remote_actor_id}
          else
            {:local, sender_id}
          end

        {key, count}
      end)
      |> Map.new()

    all_creators =
      MapSet.union(MapSet.new(Map.keys(view_counts)), MapSet.new(Map.keys(dismissal_counts)))

    all_creators
    |> Enum.map(fn creator_key ->
      views = Map.get(view_counts, creator_key, 0)
      dismissals = Map.get(dismissal_counts, creator_key, 0)
      total = views + dismissals

      rate =
        if total > 0 do
          dismissals / total
        else
          0.0
        end

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

  defp get_creator_satisfaction_scores(user_id) do
    from(s in CreatorSatisfaction, where: s.user_id == ^user_id, select: s)
    |> Repo.all()
    |> Enum.map(fn sat ->
      key =
        if sat.remote_actor_id do
          {:remote, sat.remote_actor_id}
        else
          {:local, sat.creator_id}
        end

      score = CreatorSatisfaction.satisfaction_score(sat)
      {key, score}
    end)
    |> Map.new()
  end

  @doc "Records a post dismissal (negative signal).\n"
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

  @doc "Updates or creates a post view with dwell time data.\n"
  def record_view_with_dwell(user_id, message_id, attrs \\ %{}) do
    Views.track_post_view(user_id, message_id, attrs)
  end

  defp decimal_to_int(%Decimal{} = d) do
    d |> Decimal.round(0) |> Decimal.to_integer()
  end

  defp decimal_to_int(n) when is_number(n) do
    trunc(n)
  end

  defp decimal_to_int(nil) do
    0
  end
end
