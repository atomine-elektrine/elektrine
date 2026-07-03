defmodule Elektrine.Social.Discussions do
  @moduledoc """
  Community discussion post queries and discovery.
  """

  import Ecto.Query, warn: false
  import Elektrine.Social.FeedQuery

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Social.Conversation
  alias Elektrine.Social.ConversationMember
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages, as: MessagingMessages

  @discussion_post_types ["discussion", "link", "poll"]

  @doc """
  Gets discussion posts for a community (sorted by score for forum-style).
  """
  def get_discussion_posts(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    pagination = pagination_opts(opts)
    # "score", "recent", "hot"
    sort_by = Keyword.get(opts, :sort_by, "score")
    preloads = MessagingMessages.discussion_post_preloads()

    order_clause =
      case sort_by do
        "score" -> [desc: :score, desc: :inserted_at]
        "recent" -> [desc: :inserted_at]
        "oldest" -> [asc: :inserted_at]
        "hot" -> [desc: :score, desc: :upvotes, desc: :inserted_at]
        _ -> [desc: :score, desc: :inserted_at]
      end

    base_query =
      from(m in discussion_post_query(conversation_id, opts),
        limit: ^limit,
        preload: ^preloads
      )

    query =
      if pagination_requested?(pagination) do
        base_query
        |> apply_id_pagination(pagination)
        |> apply_id_order(pagination.order)
      else
        from(m in base_query,
          order_by: ^order_clause,
          offset: ^offset
        )
      end

    query
    |> Repo.all()
  end

  @doc """
  Counts discussion posts in a community (for ActivityPub totalItems).
  """
  def count_discussion_posts(conversation_id, opts \\ []) do
    from(m in discussion_post_query(conversation_id, opts), select: count(m.id))
    |> Repo.one() || 0
  end

  defp discussion_post_query(conversation_id, opts) do
    visibility = Keyword.get(opts, :visibility)
    exclude_drafts = Keyword.get(opts, :exclude_drafts, false)
    activitypub_enabled_only = Keyword.get(opts, :activitypub_enabled_only, false)

    Message
    |> where(
      [m],
      m.conversation_id == ^conversation_id and
        (m.post_type in ^@discussion_post_types or is_nil(m.post_type)) and
        is_nil(m.deleted_at) and
        is_nil(m.reply_to_id) and
        (is_nil(m.is_pinned) or m.is_pinned == false) and
        (m.approval_status == "approved" or is_nil(m.approval_status))
    )
    |> maybe_filter_discussion_post_visibility(visibility)
    |> maybe_exclude_draft_discussion_posts(exclude_drafts)
    |> maybe_filter_activitypub_enabled_discussion_posts(activitypub_enabled_only)
  end

  defp maybe_filter_discussion_post_visibility(query, nil), do: query

  defp maybe_filter_discussion_post_visibility(query, visibility) when is_binary(visibility) do
    from(m in query, where: m.visibility == ^visibility)
  end

  defp maybe_filter_activitypub_enabled_discussion_posts(query, false), do: query

  defp maybe_filter_activitypub_enabled_discussion_posts(query, true) do
    from(m in query,
      join: u in User,
      on: u.id == m.sender_id and u.activitypub_enabled == true
    )
  end

  defp maybe_exclude_draft_discussion_posts(query, true) do
    from(m in query, where: m.is_draft != true)
  end

  defp maybe_exclude_draft_discussion_posts(query, _), do: query

  @doc """
  Gets related discussion posts from the same community.
  """
  def get_related_discussion_posts(conversation_id, current_post_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    current_post = Repo.get(Message, current_post_id)

    # Get posts from the same community, excluding the current post
    # Prioritize posts with similar hashtags or from the same author
    from(m in Message,
      left_join: h in assoc(m, :hashtags),
      # Only discussion posts
      # Top-level posts only
      # Only approved posts
      where:
        m.conversation_id == ^conversation_id and
          m.id != ^current_post_id and
          m.post_type == "discussion" and
          is_nil(m.deleted_at) and
          is_nil(m.reply_to_id) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      group_by: m.id,
      order_by: [
        # Prioritize posts from the same author
        desc: fragment("CASE WHEN ? = ? THEN 1 ELSE 0 END", m.sender_id, ^current_post.sender_id),
        # Then by score
        desc: m.score,
        desc: m.inserted_at
      ],
      limit: ^limit,
      preload: [:sender, :hashtags]
    )
    |> Repo.all()
  end

  @doc """
  Gets trending discussions across all communities.
  """
  def get_trending_discussions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    days_back = Keyword.get(opts, :days_back, 7)
    preloads = MessagingMessages.discussion_post_preloads()

    # Posts from last N days, sorted by engagement (score + reply count)
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back, :day)

    trending_discussions_query(cutoff_date, limit, preloads)
    |> Repo.all()
  end

  defp trending_discussions_query(cutoff_date, limit, preloads) do
    discussion_filter = discussion_visibility_and_type_filter()
    community_filter = public_community_filter()
    lifecycle_filter = discussion_post_lifecycle_filter()
    engagement_filter = recent_engagement_filter(cutoff_date)

    filter =
      dynamic(
        [m, c],
        ^community_filter and ^discussion_filter and ^lifecycle_filter and ^engagement_filter
      )

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: ^filter,
      order_by: [desc: fragment("? + ?", m.score, m.reply_count), desc: m.inserted_at],
      limit: ^limit,
      preload: ^preloads
    )
  end

  defp public_community_filter do
    dynamic([_m, c], c.type == "community" and c.is_public == true)
  end

  defp discussion_post_lifecycle_filter do
    dynamic(
      [m, _c],
      is_nil(m.deleted_at) and
        is_nil(m.reply_to_id) and
        (m.approval_status == "approved" or is_nil(m.approval_status))
    )
  end

  defp recent_engagement_filter(cutoff_date) do
    dynamic([m, _c], m.inserted_at > ^cutoff_date and (m.score > 0 or m.reply_count > 0))
  end

  @doc """
  Gets recent activity across all communities the user is a member of.
  """
  def get_recent_community_activity(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 15)
    preloads = MessagingMessages.discussion_post_preloads()

    # Get user's communities
    user_community_ids =
      from(cm in ConversationMember,
        join: c in Conversation,
        on: c.id == cm.conversation_id,
        where: cm.user_id == ^user_id and is_nil(cm.left_at) and c.type == "community",
        select: c.id
      )
      |> Repo.all()

    case user_community_ids do
      [] ->
        []

      _ ->
        from(m in Message,
          join: c in Conversation,
          on: c.id == m.conversation_id,
          where:
            m.conversation_id in ^user_community_ids and
              is_nil(m.deleted_at) and
              is_nil(m.reply_to_id),
          order_by: [desc: m.inserted_at],
          limit: ^limit,
          preload: ^preloads
        )
        |> Repo.all()
    end
  end

  @doc """
  Gets the user's own posts and comments in communities.
  Returns all messages where the user is the sender in:
  - Local community-type conversations
  - Remote community posts (with community_actor_uri in media_metadata)
  """
  def get_user_community_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    preloads = MessagingMessages.discussion_post_preloads()

    # Query for local community posts
    local_posts =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.sender_id == ^user_id and
            c.type == "community" and
            is_nil(m.deleted_at),
        select: m
      )

    # Query for remote community posts (posts with community_actor_uri in media_metadata)
    remote_posts =
      from(m in Message,
        where:
          m.sender_id == ^user_id and
            is_nil(m.deleted_at) and
            fragment("?->>'community_actor_uri' IS NOT NULL", m.media_metadata),
        select: m
      )

    # Union the two queries and order by inserted_at
    from(m in subquery(union_all(local_posts, ^remote_posts)),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: ^preloads
    )
    |> Repo.all()
  end

  @doc """
  Gets popular communities this week based on activity and member growth.
  """
  def get_popular_communities_this_week(opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    week_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

    from(c in Conversation,
      left_join: m in Message,
      on: m.conversation_id == c.id and m.inserted_at > ^week_ago,
      where:
        c.type == "community" and c.is_public == true and
          (is_nil(c.is_federated_mirror) or c.is_federated_mirror == false),
      group_by: [c.id, c.name, c.description, c.member_count, c.community_category],
      order_by: [desc: count(m.id), desc: c.member_count],
      limit: ^limit,
      select: %{
        id: c.id,
        name: c.name,
        description: c.description,
        member_count: c.member_count,
        category: c.community_category,
        weekly_posts: count(m.id),
        hash: c.hash
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets suggested discussion topics based on user's recent timeline and chat activity.
  """
  def get_suggested_discussion_topics(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    days_back = Keyword.get(opts, :days_back, 7)
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back, :day)

    # Get user's recent timeline posts and chat messages that could become discussions
    potential_topics =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        # Must have some engagement or be substantial
        where:
          m.sender_id == ^user_id and
            m.inserted_at > ^cutoff_date and
            is_nil(m.deleted_at) and
            ((c.type == "timeline" and m.post_type == "post") or
               (c.type == "dm" and fragment("length(?)", m.content) > 50)) and
            (m.like_count > 0 or fragment("length(?)", m.content) > 100),
        order_by: [desc: m.like_count, desc: m.inserted_at],
        limit: ^limit,
        preload: [conversation: []]
      )
      |> Repo.all()

    Enum.map(potential_topics, &build_suggested_topic/1)
  end

  defp build_suggested_topic(message) do
    %{
      message_id: message.id,
      suggested_title: suggested_discussion_title(message),
      content_preview: String.slice(message.content, 0, 100),
      source_type: suggested_topic_source_type(message),
      engagement: message.like_count || 0
    }
  end

  defp suggested_discussion_title(%{title: title} = message) when is_binary(title) do
    if Elektrine.Strings.present?(title) do
      "Discussion: #{title}"
    else
      "Discussion: #{String.slice(message.content, 0, 50)}..."
    end
  end

  defp suggested_discussion_title(message),
    do: "Discussion: #{String.slice(message.content, 0, 50)}..."

  defp suggested_topic_source_type(%{conversation: %{type: "timeline"}}), do: "timeline"
  defp suggested_topic_source_type(%{conversation: %{type: "community"}}), do: "discussion"
  defp suggested_topic_source_type(_), do: "chat"

  defp discussion_visibility_and_type_filter do
    dynamic([m], m.post_type in ^@discussion_post_types)
  end
end
