defmodule Elektrine.Social do
  @moduledoc """
  The Social context - handles timeline, following, and social features.
  Builds on top of the existing messaging system.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts
  alias Elektrine.Accounts.{BlockedUsersCache, User, UserMute}
  alias Elektrine.ActivityPub.{Instance, Mentions, UserBlock}
  alias Elektrine.ActivityPub.Outbox
  alias Elektrine.Async
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Notifications
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Security.ContentValidator

  alias Elektrine.Social.{
    Conversation,
    FeedPolicy,
    HomeFeedCache,
    Message,
    MessagePolicy,
    MessageReaction,
    PostBoost,
    PostHashtag,
    PostLike,
    SuggestedAccountDismissal,
    TimelinePagination,
    TimelineRelationships
  }

  alias Elektrine.Social.{ConversationMember, HashtagFollow}
  alias Elektrine.Social.{FetchLinkPreviewWorker, Hashtag, HashtagExtractor, LinkPreviewFetcher}
  alias Elektrine.Social.Messages, as: MessagingMessages
  @discussion_post_types ["discussion", "link", "poll"]
  @profile_pin_limit 3
  @profile_pin_visibilities ["public", "unlisted"]
  @public_audience_uris ["Public", "as:Public", "https://www.w3.org/ns/activitystreams#Public"]

  ## Following System

  # Use existing Profiles follow functions instead of duplicating
  defdelegate follow_user(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate unfollow_user(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate following?(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate get_follower_count(user_id), to: Elektrine.Profiles
  defdelegate get_following_count(user_id), to: Elektrine.Profiles

  ## Bookmarks (Saved Items) - Delegated to Elektrine.Social.Bookmarks
  defdelegate save_post(user_id, message_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate save_rss_item(user_id, rss_item_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate unsave_post(user_id, message_id), to: Elektrine.Social.Bookmarks
  defdelegate unsave_rss_item(user_id, rss_item_id), to: Elektrine.Social.Bookmarks
  defdelegate post_saved?(user_id, message_id), to: Elektrine.Social.Bookmarks
  defdelegate rss_item_saved?(user_id, rss_item_id), to: Elektrine.Social.Bookmarks
  defdelegate list_user_saved_posts(user_id, message_ids), to: Elektrine.Social.Bookmarks
  defdelegate list_user_saved_rss_items(user_id, rss_item_ids), to: Elektrine.Social.Bookmarks
  defdelegate get_saved_posts(user_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate get_saved_rss_items(user_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate count_saved_posts(user_id), to: Elektrine.Social.Bookmarks

  defdelegate list_bookmark_folders(user_id),
    to: Elektrine.Social.BookmarkFolders,
    as: :list_folders

  defdelegate get_bookmark_folder(id, user_id),
    to: Elektrine.Social.BookmarkFolders,
    as: :get_folder

  defdelegate create_bookmark_folder(user_id, attrs),
    to: Elektrine.Social.BookmarkFolders,
    as: :create_folder

  defdelegate update_bookmark_folder(folder, attrs),
    to: Elektrine.Social.BookmarkFolders,
    as: :update_folder

  defdelegate delete_bookmark_folder(id, user_id),
    to: Elektrine.Social.BookmarkFolders,
    as: :delete_folder

  ## Post View Tracking - Delegated to Elektrine.Social.Views
  defdelegate track_post_view(user_id, message_id, opts \\ []), to: Elektrine.Social.Views
  defdelegate get_user_viewed_posts(user_id, opts \\ []), to: Elektrine.Social.Views
  defdelegate get_post_view_count(message_id), to: Elektrine.Social.Views
  defdelegate user_viewed_post?(user_id, message_id), to: Elektrine.Social.Views

  ## Likes - Delegated to Elektrine.Social.Likes
  defdelegate like_post(user_id, message_id), to: Elektrine.Social.Likes
  defdelegate unlike_post(user_id, message_id), to: Elektrine.Social.Likes
  defdelegate user_liked_post?(user_id, message_id), to: Elektrine.Social.Likes
  defdelegate list_user_likes(user_id, message_ids), to: Elektrine.Social.Likes
  defdelegate get_liked_posts(user_id, opts \\ []), to: Elektrine.Social.Likes

  ## Boosts - Delegated to Elektrine.Social.Boosts
  defdelegate boost_post(user_id, message_id), to: Elektrine.Social.Boosts
  defdelegate unboost_post(user_id, message_id), to: Elektrine.Social.Boosts
  defdelegate list_user_boosts(user_id, message_ids), to: Elektrine.Social.Boosts

  defdelegate create_quote_post(user_id, quoted_message_id, content, opts \\ []),
    to: Elektrine.Social.Boosts

  defdelegate user_boosted?(user_id, message_id), to: Elektrine.Social.Boosts

  ## Votes (Discussion Voting) - Delegated to Elektrine.Social.Votes
  defdelegate vote_on_message(user_id, message_id, vote_type), to: Elektrine.Social.Votes
  defdelegate get_user_vote(user_id, message_id), to: Elektrine.Social.Votes
  defdelegate get_user_votes(user_id, message_ids), to: Elektrine.Social.Votes
  defdelegate get_message_voters(message_id, limit \\ 100), to: Elektrine.Social.Votes

  defdelegate get_message_voters_paginated(message_id, vote_type, opts \\ []),
    to: Elektrine.Social.Votes

  defdelegate calculate_engagement_score(message_id, upvotes, downvotes),
    to: Elektrine.Social.Votes

  defdelegate recalculate_all_scores(), to: Elektrine.Social.Votes
  defdelegate recalculate_recent_discussion_scores(), to: Elektrine.Social.Votes

  def status_visible?(user_id, %Message{} = message), do: MessagePolicy.visible?(user_id, message)
  def status_visible?(_user_id, _message), do: false

  def status_explicit_visible?(user_id, message, opts \\ [])

  def status_explicit_visible?(user_id, %Message{} = message, opts) do
    relationships = TimelineRelationships.load(user_id, [message])
    status_explicit_visible?(user_id, message, opts, relationships)
  end

  def status_explicit_visible?(_user_id, _message, _opts), do: false

  def status_explicit_visible?(user_id, %Message{} = message, opts, relationships) do
    MessagePolicy.visible?(user_id, message) and
      if Keyword.get(opts, :with_muted, false) do
        not TimelineRelationships.blocked_message_except_mutes?(relationships, message)
      else
        not TimelineRelationships.blocked_message?(relationships, message)
      end
  end

  def filter_explicit_visible_statuses(user_id, statuses, opts \\ [])

  def filter_explicit_visible_statuses(user_id, statuses, opts)
      when is_integer(user_id) and is_list(statuses) do
    relationships = TimelineRelationships.load(user_id, statuses)

    Enum.filter(statuses, &status_explicit_visible?(user_id, &1, opts, relationships))
  end

  def filter_explicit_visible_statuses(_user_id, _statuses, _opts), do: []

  def status_liked_by_accounts(message_id, limit \\ 80) do
    from(like in PostLike,
      join: account in assoc(like, :user),
      where: like.message_id == ^message_id,
      order_by: [desc: like.id],
      limit: ^limit,
      select: account
    )
    |> Repo.all()
  end

  def status_boosted_by_accounts(message_id, limit \\ 80) do
    from(boost in PostBoost,
      join: account in assoc(boost, :user),
      where: boost.message_id == ^message_id,
      order_by: [desc: boost.id],
      limit: ^limit,
      select: account
    )
    |> Repo.all()
  end

  def list_status_quotes(message_id, viewer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()

    from(message in Message,
      where:
        message.quoted_message_id == ^message_id and
          message.is_draft != true and
          is_nil(message.deleted_at) and
          (message.approval_status == "approved" or is_nil(message.approval_status)),
      order_by: [desc: message.id],
      limit: ^(limit * 3),
      preload: ^preloads
    )
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> Repo.all()
    |> Enum.filter(&MessagePolicy.visible?(viewer_id, &1))
    |> Enum.take(limit)
  end

  def list_status_reactions(message_id, opts \\ []) do
    emoji = Keyword.get(opts, :emoji)

    query =
      from(reaction in MessageReaction,
        where: reaction.message_id == ^message_id,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        preload: [:user, :remote_actor]
      )

    query =
      if is_binary(emoji) and emoji != "" do
        from(reaction in query, where: reaction.emoji == ^emoji)
      else
        query
      end

    Repo.all(query)
  end

  def add_status_reaction(user_id, message_id, emoji)
      when is_integer(user_id) and is_binary(emoji) do
    with %Message{} = message <- Repo.get(Message, message_id),
         true <- MessagePolicy.visible?(user_id, message) do
      case Repo.get_by(MessageReaction, message_id: message.id, user_id: user_id, emoji: emoji) do
        %MessageReaction{} = reaction -> {:ok, reaction}
        nil -> Elektrine.Messaging.add_reaction(message.id, user_id, emoji)
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def add_status_reaction(_user_id, _message_id, _emoji), do: {:error, :not_found}

  def remove_status_reaction(user_id, message_id, emoji)
      when is_integer(user_id) and is_binary(emoji) do
    with %Message{} = message <- Repo.get(Message, message_id),
         true <- MessagePolicy.visible?(user_id, message) do
      Elektrine.Messaging.remove_reaction(message.id, user_id, emoji)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def remove_status_reaction(_user_id, _message_id, _emoji), do: {:error, :not_found}

  ## Hashtag System
  defdelegate get_posts_for_hashtag(hashtag_name, opts \\ []), to: HashtagExtractor
  defdelegate get_trending_hashtags(opts \\ []), to: HashtagExtractor
  defdelegate search_hashtags(query, limit \\ 10), to: HashtagExtractor

  @doc """
  Gets or creates a hashtag by name.
  """
  def get_or_create_hashtag(name) do
    normalized_name = String.downcase(name)

    case first_hashtag_by_normalized_name(normalized_name) do
      nil ->
        case %Hashtag{}
             |> Hashtag.changeset(%{
               name: name,
               normalized_name: normalized_name,
               use_count: 0,
               last_used_at: DateTime.utc_now()
             })
             |> Repo.insert(
               on_conflict: :nothing,
               conflict_target: :normalized_name,
               returning: true
             ) do
          {:ok, hashtag} ->
            if hashtag.id, do: hashtag, else: first_hashtag_by_normalized_name(normalized_name)

          {:error, _} ->
            first_hashtag_by_normalized_name(normalized_name)
        end

      hashtag ->
        hashtag
    end
  end

  @doc """
  Increments the usage count for a hashtag.
  """
  def increment_hashtag_usage(hashtag_id) do
    from(h in Hashtag, where: h.id == ^hashtag_id)
    |> Repo.update_all(
      inc: [use_count: 1],
      set: [last_used_at: Elektrine.Time.utc_now()]
    )
  end

  @doc """
  Decrements the usage count for a hashtag without letting it go negative.
  """
  def decrement_hashtag_usage(hashtag_id) do
    case Repo.get(Hashtag, hashtag_id) do
      %Hashtag{use_count: count} when count > 0 ->
        from(h in Hashtag, where: h.id == ^hashtag_id)
        |> Repo.update_all(
          inc: [use_count: -1],
          set: [last_used_at: Elektrine.Time.utc_now()]
        )

      _ ->
        {0, nil}
    end
  end

  @doc """
  Gets a hashtag by its normalized name.
  """
  def get_hashtag_by_normalized_name(normalized_name) do
    normalized_name
    |> String.downcase()
    |> first_hashtag_by_normalized_name()
  end

  defp first_hashtag_by_normalized_name(normalized_name) do
    from(h in Hashtag,
      where: h.normalized_name == ^normalized_name,
      order_by: [asc: h.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Counts posts with a specific hashtag (for ActivityPub collections).
  """
  def count_hashtag_posts(hashtag_id, opts \\ []) do
    hashtag_posts_query(hashtag_id, opts)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Lists posts with a specific hashtag (for ActivityPub collections).
  """
  def list_hashtag_posts(hashtag_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    preload = Keyword.get(opts, :preload, [])

    query =
      from(m in hashtag_posts_query(hashtag_id, opts),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query
    |> Repo.all()
    |> Repo.preload(preload)
  end

  defp hashtag_posts_query(hashtag_id, opts) do
    visibility = Keyword.get(opts, :visibility)
    exclude_drafts = Keyword.get(opts, :exclude_drafts, false)
    activitypub_enabled_only = Keyword.get(opts, :activitypub_enabled_only, false)

    Message
    |> join(:inner, [m], ph in "post_hashtags", on: ph.message_id == m.id)
    |> join(:inner, [m, ph], c in Conversation, on: c.id == m.conversation_id)
    |> where([m, ph, _c], ph.hashtag_id == ^hashtag_id and is_nil(m.deleted_at))
    |> where([_m, _ph, c], c.type != "community" or c.is_public == true)
    |> maybe_filter_hashtag_post_visibility(visibility)
    |> maybe_exclude_hashtag_drafts(exclude_drafts)
    |> maybe_filter_activitypub_enabled_hashtag_posts(activitypub_enabled_only)
  end

  defp maybe_filter_hashtag_post_visibility(query, nil), do: query

  defp maybe_filter_hashtag_post_visibility(query, visibility) do
    from(m in query, where: m.visibility == ^visibility)
  end

  defp maybe_exclude_hashtag_drafts(query, false), do: query
  defp maybe_exclude_hashtag_drafts(query, true), do: from(m in query, where: m.is_draft != true)

  defp maybe_filter_activitypub_enabled_hashtag_posts(query, false), do: query

  defp maybe_filter_activitypub_enabled_hashtag_posts(query, true) do
    from([m, _ph, _c] in query,
      join: u in User,
      on: u.id == m.sender_id and u.activitypub_enabled == true
    )
  end

  ## Timeline/Posts

  @doc """
  Creates a timeline post (uses existing message system).
  """
  def create_timeline_post(user_id, content, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, "followers")
    media_urls = Keyword.get(opts, :media_urls, [])
    alt_texts = Keyword.get(opts, :alt_texts, %{})
    media_metadata = Keyword.get(opts, :media_metadata, %{})
    title = Keyword.get(opts, :title)
    post_type = Keyword.get(opts, :post_type, "post")
    category = Keyword.get(opts, :category)
    community_actor_uri = Keyword.get(opts, :community_actor_uri)
    primary_url = Keyword.get(opts, :primary_url)

    # Security checks
    with :ok <-
           RateLimiter.can_create_timeline_post?(user_id)
           |> rate_limit_to_ok(),
         {:ok, user} <- get_user_with_permissions(user_id),
         :ok <- ContentValidator.check_user_permissions(user, :create_post),
         {:ok, validated_content} <- validate_content_or_allow_empty(content, media_urls),
         {:ok, validated_title} <- validate_title_if_present(title) do
      extracted_urls = LinkPreviewFetcher.extract_urls(validated_content)
      extracted_hashtags = HashtagExtractor.extract_hashtags(validated_content)
      timeline_conversation = get_or_create_user_timeline(user_id)
      {link_preview_id, auto_title} = resolve_link_preview(extracted_urls)

      attrs =
        build_timeline_post_attrs(%{
          user_id: user_id,
          validated_content: validated_content,
          media_urls: media_urls,
          visibility: visibility,
          post_type: post_type,
          opts: opts,
          conversation_id: timeline_conversation.id,
          extracted_urls: extracted_urls,
          extracted_hashtags: extracted_hashtags,
          link_preview_id: link_preview_id,
          validated_title: validated_title,
          auto_title: auto_title,
          base_media_metadata: media_metadata,
          alt_texts: alt_texts,
          community_actor_uri: community_actor_uri,
          category: category,
          primary_url: primary_url
        })

      persist_timeline_post(attrs, user_id, validated_content, extracted_hashtags)
    else
      error -> error
    end
  end

  @doc """
  Gets timeline feed for a user (posts from people they follow + their own).
  Handles different visibility levels:
  - public: everyone can see
  - followers: only followers can see
  - friends: only friends can see
  - private: only author can see
  """
  def get_timeline_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()

    # Get list of users this person follows + themselves
    following_ids = get_following_user_ids(user_id)

    # Get list of friends
    friend_ids = Friends.list_friends(user_id) |> Enum.map(& &1.id)

    # Get list of blocked users (both ways - cached for performance)
    all_blocked_ids = blocked_user_ids(user_id)

    visibility_filter = timeline_sender_visibility_filter(user_id, following_ids, friend_ids)

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        # Own posts (all visibilities)
        # Public posts from anyone followed
        # Followers posts from people they follow
        # Friends posts from friends
        where:
          c.type == "timeline" and
            m.post_type == "post" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            m.sender_id not in ^all_blocked_ids,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = from(m in query, where: ^visibility_filter)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets direct timeline posts visible to a user.
  """
  def get_direct_timeline(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      left_join: cm in ConversationMember,
      on:
        cm.conversation_id == m.conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at),
      where:
        c.type in ["timeline", "dm"] and
          m.post_type == "post" and
          m.visibility == "direct" and
          (m.sender_id == ^user_id or not is_nil(cm.id)) and
          m.is_draft != true and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      order_by: [desc: m.id],
      limit: ^(limit * 3),
      preload: ^preloads
    )
    |> maybe_exclude_blocked_senders(all_blocked_ids)
    |> maybe_apply_viewer_timeline_policy(user_id)
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> Repo.all()
    |> Enum.filter(&MessagePolicy.visible?(user_id, &1))
    |> Enum.take(limit)
  end

  @doc """
  Gets public timeline (discovery feed).
  """
  def get_public_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    only_media = Keyword.get(opts, :only_media, false)
    preloads = MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    timeline_scope_filter = public_timeline_scope_filter()

    query =
      from m in Message,
        left_join: c in Conversation,
        on: c.id == m.conversation_id,
        # Exclude federated comments (Lemmy comments have inReplyTo in metadata)
        where:
          m.visibility == "public" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata),
        # Use id for ordering since federated posts have inserted_at set to their
        # original published date, not when received. This ensures pagination works.
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = from(m in query, where: ^timeline_scope_filter)
    query = maybe_exclude_blocked_senders_or_nil(query, all_blocked_ids)
    query = maybe_apply_viewer_timeline_policy(query, user_id)
    query = maybe_exclude_public_timeline_removed_instances(query)
    query = maybe_apply_timeline_search(query, search_query)
    query = maybe_filter_timeline_media(query, only_media)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets public community posts for timeline community view.
  Includes federated community posts tagged via metadata or linked to mirror conversations.
  """
  def get_public_community_posts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    source_filter = Keyword.get(opts, :source_filter, "all")
    preloads = [conversation: []] ++ MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    source_scope_filter =
      case source_filter do
        "federated" ->
          dynamic(
            [m, c],
            (m.federated == true and
               (c.type == "community" or
                  fragment("?->>'community_actor_uri' IS NOT NULL", m.media_metadata))) or
              c.is_federated_mirror == true
          )

        "local" ->
          dynamic(
            [m, c],
            c.type == "community" and
              (is_nil(c.is_federated_mirror) or c.is_federated_mirror == false) and
              m.federated != true
          )

        _ ->
          dynamic(
            [m, c],
            c.type == "community" or
              fragment("?->>'community_actor_uri' IS NOT NULL", m.media_metadata)
          )
      end

    where_filter =
      dynamic(
        [m, c],
        m.visibility == "public" and
          m.is_draft != true and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)) and
          is_nil(m.reply_to_id) and
          fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
          ^source_scope_filter
      )

    query =
      from m in Message,
        left_join: c in Conversation,
        on: c.id == m.conversation_id,
        where: ^where_filter,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders_or_nil(query, all_blocked_ids)
    query = maybe_apply_viewer_timeline_policy(query, user_id)
    query = maybe_exclude_public_timeline_removed_instances(query)
    query = maybe_apply_timeline_search(query, search_query)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets trending timeline (posts with high engagement).
  """
  def get_trending_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    preloads = MessagingMessages.timeline_feed_preloads()

    all_blocked_ids = blocked_user_ids(user_id)

    # Posts from last 7 days, sorted by engagement
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

    query =
      from m in Message,
        left_join: c in Conversation,
        on: c.id == m.conversation_id,
        # Exclude federated comments (Lemmy comments have inReplyTo in metadata)
        where:
          ((c.type == "timeline" and m.post_type == "post") or
             (is_nil(m.conversation_id) and m.federated == true)) and
            m.visibility in ["public", "followers"] and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            m.inserted_at > ^seven_days_ago,
        order_by: [desc: m.like_count, desc: m.reply_count, desc: m.inserted_at],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders_or_nil(query, all_blocked_ids)
    query = maybe_apply_viewer_timeline_policy(query, user_id)
    query = maybe_exclude_public_timeline_removed_instances(query)
    query = apply_id_pagination(query, pagination)

    Repo.all(query)
  end

  @doc """
  Gets replies that belong to federated threads.

  Includes:
  - local replies to federated parent posts
  - federated replies that include an `inReplyTo` reference
  """
  def get_federated_replies(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    source_filter = Keyword.get(opts, :source_filter)
    preloads = MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    base_query =
      from m in Message,
        left_join: parent in Message,
        on: parent.id == m.reply_to_id,
        left_join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.visibility == "public" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            ((not is_nil(m.reply_to_id) and parent.federated == true) or
               fragment("(?->>'inReplyTo' IS NOT NULL)", m.media_metadata)) and
            (c.type == "timeline" or (is_nil(m.conversation_id) and m.federated == true)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query =
      case source_filter do
        "federated" -> from [m, _parent, _c] in base_query, where: m.federated == true
        _ -> base_query
      end

    query = maybe_exclude_blocked_senders_or_nil(query, all_blocked_ids)
    query = maybe_apply_viewer_timeline_policy(query, user_id)
    query = maybe_exclude_public_timeline_removed_instances(query)
    query = maybe_apply_timeline_search(query, search_query)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets timeline posts from local friends.
  """
  def get_friends_timeline(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    search_query = Keyword.get(opts, :search_query)
    preloads = MessagingMessages.timeline_feed_preloads()
    friend_ids = Friends.list_friends(user_id) |> Enum.map(& &1.id)
    all_blocked_ids = blocked_user_ids(user_id)

    if Enum.empty?(friend_ids) do
      []
    else
      query =
        from m in Message,
          join: c in Conversation,
          on: c.id == m.conversation_id,
          where:
            c.type == "timeline" and
              m.post_type == "post" and
              m.sender_id in ^friend_ids and
              m.visibility in ["public", "followers", "friends"] and
              m.is_draft != true and
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status)) and
              is_nil(m.reply_to_id) and
              fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata),
          order_by: [desc: m.id],
          limit: ^limit,
          preload: ^preloads

      query = maybe_exclude_blocked_senders(query, all_blocked_ids)
      query = maybe_exclude_blocked_instances(query)
      query = maybe_apply_timeline_search(query, search_query)
      query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

      Repo.all(query)
    end
  end

  @doc """
  Gets local public timeline posts from trusted users (TL2+).
  """
  def get_trusted_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    preloads = MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        join: u in User,
        on: u.id == m.sender_id,
        where:
          c.type == "timeline" and
            m.post_type == "post" and
            is_nil(m.remote_actor_id) and
            m.visibility == "public" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            u.trust_level >= 2,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
    query = maybe_exclude_blocked_instances(query)
    query = maybe_apply_timeline_search(query, search_query)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets gallery feed for a user (posts from people they follow with post_type: "gallery").
  """
  def get_gallery_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    following_only = Keyword.get(opts, :following_only, false)

    # Get list of users this person follows
    following_ids = get_following_user_ids(user_id)

    # Get list of blocked users (both ways - cached for performance)
    all_blocked_ids = BlockedUsersCache.get_all_blocked_user_ids(user_id)

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          c.type == "timeline" and
            m.post_type == "gallery" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            m.sender_id not in ^all_blocked_ids,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: [sender: [:profile]]

    # Filter based on following_only option
    query =
      if following_only do
        from m in query, where: m.sender_id in ^following_ids
      else
        from m in query, where: m.sender_id in ^following_ids or m.visibility == "public"
      end

    query
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> maybe_exclude_blocked_instances()
    |> Repo.all()
  end

  @doc """
  Gets pinned posts for a user.
  """
  def get_pinned_posts(user_id, opts \\ []) do
    viewer_id = Keyword.get(opts, :viewer_id)
    preloads = MessagingMessages.timeline_feed_preloads()
    visibility_levels = visibility_levels_for_viewer(user_id, viewer_id)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        c.type == "timeline" and
          m.sender_id == ^user_id and
          m.is_pinned == true and
          m.is_draft != true and
          m.visibility in ^visibility_levels and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 3,
      preload: ^preloads
    )
    |> Repo.all()
  end

  @doc """
  Gets profile statuses for API clients with common account-status filters.
  """
  def get_account_statuses(user_id, opts \\ []) do
    if Keyword.get(opts, :pinned, false) do
      get_pinned_posts(user_id, opts)
    else
      limit = Keyword.get(opts, :limit, 20)
      pagination = pagination_opts(opts)
      viewer_id = Keyword.get(opts, :viewer_id)
      preloads = MessagingMessages.timeline_feed_preloads()
      visibility_levels = visibility_levels_for_viewer(user_id, viewer_id)

      query =
        from(m in Message,
          join: c in Conversation,
          on: c.id == m.conversation_id,
          where:
            c.type == "timeline" and
              m.sender_id == ^user_id and
              m.post_type == "post" and
              m.is_draft != true and
              m.visibility in ^visibility_levels and
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status)),
          order_by: [desc: m.id],
          limit: ^limit,
          preload: ^preloads
        )

      query
      |> maybe_filter_timeline_media(Keyword.get(opts, :only_media, false))
      |> maybe_filter_account_status_reblogs(
        Keyword.get(opts, :exclude_reblogs, false),
        Keyword.get(opts, :only_reblogs, false)
      )
      |> maybe_filter_account_status_replies(Keyword.get(opts, :exclude_replies, false))
      |> apply_id_pagination(pagination)
      |> apply_id_order(pagination.order)
      |> Repo.all()
    end
  end

  defp maybe_filter_timeline_media(query, true) do
    from(m in query, where: fragment("array_length(?, 1) > 0", m.media_urls))
  end

  defp maybe_filter_timeline_media(query, _only_media), do: query

  defp maybe_filter_account_status_reblogs(query, _exclude_reblogs, true) do
    from(m in query, where: not is_nil(m.shared_message_id))
  end

  defp maybe_filter_account_status_reblogs(query, true, _only_reblogs) do
    from(m in query, where: is_nil(m.shared_message_id))
  end

  defp maybe_filter_account_status_reblogs(query, _exclude_reblogs, _only_reblogs), do: query

  defp maybe_filter_account_status_replies(query, true) do
    from(m in query,
      where:
        is_nil(m.reply_to_id) and
          fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata)
    )
  end

  defp maybe_filter_account_status_replies(query, _exclude_replies), do: query

  @doc """
  Pins one of the user's own profile timeline posts.
  """
  def pin_timeline_post(user_id, message_id) when is_integer(user_id) do
    with %Message{} = message <- get_timeline_pin_candidate(message_id),
         :ok <- authorize_profile_pin(user_id, message),
         :ok <- validate_profile_pin_visibility(message),
         :ok <- validate_profile_pin_limit(user_id, message),
         {:ok, updated_message} <- update_profile_pin(message, true, user_id) do
      broadcast_profile_pin(user_id, :profile_post_pinned, updated_message)
      {:ok, updated_message}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  def pin_timeline_post(_user_id, _message_id), do: {:error, :unauthorized}

  @doc """
  Unpins one of the user's own profile timeline posts.
  """
  def unpin_timeline_post(user_id, message_id) when is_integer(user_id) do
    with %Message{} = message <- get_timeline_pin_candidate(message_id),
         :ok <- authorize_profile_pin(user_id, message),
         {:ok, updated_message} <- update_profile_pin(message, false, user_id) do
      broadcast_profile_pin(user_id, :profile_post_unpinned, updated_message)
      {:ok, updated_message}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  def unpin_timeline_post(_user_id, _message_id), do: {:error, :unauthorized}

  defp get_timeline_pin_candidate(message_id) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.id == ^message_id and
          c.type == "timeline" and
          m.post_type == "post" and
          m.is_draft != true and
          is_nil(m.deleted_at),
      preload: [conversation: c]
    )
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  defp authorize_profile_pin(user_id, %Message{sender_id: user_id}), do: :ok
  defp authorize_profile_pin(_user_id, _message), do: {:error, :unauthorized}

  defp validate_profile_pin_visibility(%Message{visibility: visibility})
       when visibility in @profile_pin_visibilities,
       do: :ok

  defp validate_profile_pin_visibility(_message), do: {:error, :invalid_visibility}

  defp validate_profile_pin_limit(_user_id, %Message{is_pinned: true}), do: :ok

  defp validate_profile_pin_limit(user_id, %Message{id: message_id}) do
    pinned_count =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          c.type == "timeline" and
            m.sender_id == ^user_id and
            m.id != ^message_id and
            m.is_pinned == true and
            m.is_draft != true and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Repo.one()

    if pinned_count < @profile_pin_limit do
      :ok
    else
      {:error, :pin_limit_reached}
    end
  end

  defp update_profile_pin(%Message{} = message, true, user_id) do
    message
    |> Ecto.Changeset.change(%{
      is_pinned: true,
      pinned_at: DateTime.utc_now() |> DateTime.truncate(:second),
      pinned_by_id: user_id
    })
    |> Repo.update()
  end

  defp update_profile_pin(%Message{} = message, false, _user_id) do
    message
    |> Ecto.Changeset.change(%{is_pinned: false, pinned_at: nil, pinned_by_id: nil})
    |> Repo.update()
  end

  defp broadcast_profile_pin(user_id, event, %Message{} = message) do
    Phoenix.PubSub.broadcast(Elektrine.PubSub, "profile:#{user_id}", {event, message})
  end

  def get_user_timeline_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    pagination = pagination_opts(opts)
    viewer_id = Keyword.get(opts, :viewer_id)
    search_query = Keyword.get(opts, :search_query)
    preloads = MessagingMessages.timeline_feed_preloads()
    visibility_levels = visibility_levels_for_viewer(user_id, viewer_id)

    query =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.sender_id == ^user_id and
            m.post_type == "post" and
            m.is_draft != true and
            m.visibility in ^visibility_levels and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> maybe_apply_timeline_search(search_query)
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> Repo.all()
  end

  @doc """
  Gets media posts for a user (posts with images).
  Returns posts that have media_urls (images/attachments).
  """
  def get_user_media_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    viewer_id = Keyword.get(opts, :viewer_id)
    visibility_levels = visibility_levels_for_viewer(user_id, viewer_id)

    from(m in Message,
      where:
        m.sender_id == ^user_id and
          m.visibility in ^visibility_levels and
          m.is_draft != true and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)) and
          fragment("array_length(?, 1)", m.media_urls) > 0,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [sender: [:profile]]
    )
    |> Repo.all()
    |> Enum.filter(fn post ->
      # Filter to only include image posts (not video/audio)
      has_image_media?(post.media_urls)
    end)
  end

  # Check if media_urls contains image files
  defp has_image_media?(nil), do: false
  defp has_image_media?([]), do: false

  defp has_image_media?(urls) when is_list(urls) do
    Enum.any?(urls, fn url ->
      is_binary(url) &&
        (String.match?(url, ~r/\.(jpe?g|png|gif|webp|svg|bmp|avif)(\?.*)?$/i) ||
           String.match?(
             url,
             ~r/(\/media\/|\/images\/|\/uploads\/|\/pictrs\/|i\.imgur|pbs\.twimg|i\.redd\.it)/i
           ))
    end)
  end

  # NOTE: Likes System functions are now in Elektrine.Social.Likes
  # NOTE: Boosts System functions are now in Elektrine.Social.Boosts
  # These are delegated at the top of this module.

  ## Private Functions

  defp maybe_apply_timeline_search(nil, _), do: nil

  defp maybe_apply_timeline_search(query, search_query) when is_binary(search_query) do
    if Elektrine.Strings.present?(search_query) do
      pattern = "%" <> search_query <> "%"

      from(m in query,
        left_join: sender in assoc(m, :sender),
        left_join: remote_actor in assoc(m, :remote_actor),
        where:
          ilike(m.content, ^pattern) or
            (not is_nil(m.title) and ilike(m.title, ^pattern)) or
            (not is_nil(sender.username) and ilike(sender.username, ^pattern)) or
            (not is_nil(sender.display_name) and ilike(sender.display_name, ^pattern)) or
            (not is_nil(remote_actor.username) and ilike(remote_actor.username, ^pattern)) or
            (not is_nil(remote_actor.display_name) and ilike(remote_actor.display_name, ^pattern)) or
            (not is_nil(remote_actor.domain) and ilike(remote_actor.domain, ^pattern))
      )
    else
      query
    end
  end

  defp maybe_apply_timeline_search(query, _), do: query

  defp get_following_user_ids(user_id) do
    following =
      from(f in Follow,
        where: f.follower_id == ^user_id,
        select: f.followed_id
      )
      |> Repo.all()

    # Include self so your own posts always appear in your feed
    [user_id | following] |> Enum.uniq()
  end

  def merge_post_media_metadata(
        base_metadata \\ %{},
        alt_texts \\ %{},
        community_actor_uri \\ nil
      )

  def merge_post_media_metadata(base_metadata, alt_texts, community_actor_uri) do
    base_metadata
    |> normalize_media_metadata()
    |> maybe_merge_attachment_alt_texts(alt_texts)
    |> maybe_put_alt_texts(alt_texts)
    |> maybe_put_community_actor_uri(community_actor_uri)
  end

  def update_media_attachment_metadata(user_id, media_id, attrs)
      when is_integer(user_id) and is_binary(media_id) and is_map(attrs) do
    normalized_media_id = normalize_media_attachment_lookup_id(media_id)

    with %Message{} = message <- get_owned_message_for_media(user_id, normalized_media_id),
         {:ok, metadata, attachment} <-
           put_media_attachment_metadata(message, normalized_media_id, attrs),
         {:ok, _updated_message} <-
           MessagingMessages.update_message_metadata(message, %{media_metadata: metadata}) do
      {:ok, attachment}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_media_attachment_metadata(_user_id, _media_id, _attrs), do: {:error, :not_found}

  defp build_media_metadata(base_metadata, alt_texts, community_actor_uri) do
    merge_post_media_metadata(base_metadata, alt_texts, community_actor_uri)
  end

  defp get_owned_message_for_media(user_id, media_id) do
    metadata_match = %{"attachments" => [%{"id" => media_id}]}

    from(m in Message,
      where: m.sender_id == ^user_id,
      where: is_nil(m.deleted_at),
      where: fragment("? = ANY(?)", ^media_id, m.media_urls),
      or_where:
        m.sender_id == ^user_id and is_nil(m.deleted_at) and
          fragment("? @> ?", m.media_metadata, ^metadata_match),
      limit: 1
    )
    |> Repo.one()
  end

  defp put_media_attachment_metadata(%Message{} = message, media_id, attrs) do
    media_urls = message.media_urls || []
    metadata = normalize_media_metadata(message.media_metadata || %{})
    attachments = metadata |> Map.get("attachments", []) |> normalize_existing_media_attachments()

    with {:ok, index, url, attachment} <-
           find_media_attachment(media_urls, attachments, media_id),
         {:ok, updates} <- media_attachment_updates(attrs) do
      updated_attachment =
        attachment
        |> Map.put_new("id", media_attachment_id(url))
        |> Map.put("url", url)
        |> apply_media_attachment_updates(updates)

      updated_attachments = put_media_attachment_at(attachments, index, updated_attachment)

      updated_metadata =
        metadata
        |> Map.put("attachments", updated_attachments)
        |> put_media_attachment_alt_text(index, updates)

      {:ok, updated_metadata, updated_attachment}
    end
  end

  defp find_media_attachment(media_urls, attachments, media_id) do
    media_urls
    |> Enum.with_index()
    |> Enum.find(fn {url, _index} -> media_attachment_ref_matches?(url, media_id) end)
    |> case do
      {url, index} ->
        attachment = Enum.at(attachments, index) || %{}
        {:ok, index, url, attachment}

      nil ->
        find_media_attachment_by_metadata(attachments, media_id)
    end
  end

  defp find_media_attachment_by_metadata(attachments, media_id) do
    attachments
    |> Enum.with_index()
    |> Enum.find(fn {attachment, _index} ->
      media_attachment_ref_matches?(attachment["id"], media_id) ||
        media_attachment_ref_matches?(attachment["url"], media_id)
    end)
    |> case do
      {%{"url" => url} = attachment, index} when is_binary(url) ->
        {:ok, index, url, attachment}

      _ ->
        {:error, :not_found}
    end
  end

  defp media_attachment_ref_matches?(ref, media_id) when is_binary(ref) do
    ref == media_id || media_attachment_id(ref) == media_id
  end

  defp media_attachment_ref_matches?(_ref, _media_id), do: false

  defp media_attachment_updates(attrs) do
    description = media_attachment_description(attrs)
    focus = media_attachment_focus(attrs)

    case {Map.has_key?(attrs, "description") || Map.has_key?(attrs, "text") ||
            Map.has_key?(attrs, "alt_text"), focus} do
      {false, nil} -> {:error, :empty_media_update}
      _ -> {:ok, %{description: description, focus: focus}}
    end
  end

  defp media_attachment_description(attrs) do
    cond do
      Map.has_key?(attrs, "description") -> attrs["description"]
      Map.has_key?(attrs, "text") -> attrs["text"]
      Map.has_key?(attrs, "alt_text") -> attrs["alt_text"]
      true -> :unchanged
    end
  end

  defp media_attachment_focus(%{"focus" => focus}), do: normalize_media_attachment_focus(focus)
  defp media_attachment_focus(_attrs), do: nil

  defp normalize_media_attachment_focus(%{"x" => x, "y" => y}) do
    with {:ok, parsed_x} <- parse_media_attachment_focus_axis(x),
         {:ok, parsed_y} <- parse_media_attachment_focus_axis(y) do
      %{"x" => parsed_x, "y" => parsed_y}
    else
      _ -> nil
    end
  end

  defp normalize_media_attachment_focus(%{x: x, y: y}) do
    normalize_media_attachment_focus(%{"x" => x, "y" => y})
  end

  defp normalize_media_attachment_focus(focus) when is_binary(focus) do
    case String.split(focus, ",", parts: 2) do
      [x, y] -> normalize_media_attachment_focus(%{"x" => x, "y" => y})
      _ -> nil
    end
  end

  defp normalize_media_attachment_focus(_focus), do: nil

  defp parse_media_attachment_focus_axis(value) when is_float(value),
    do: {:ok, clamp_focus(value)}

  defp parse_media_attachment_focus_axis(value) when is_integer(value),
    do: {:ok, clamp_focus(value / 1)}

  defp parse_media_attachment_focus_axis(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, clamp_focus(float)}
      _ -> :error
    end
  end

  defp parse_media_attachment_focus_axis(_value), do: :error

  defp clamp_focus(value), do: value |> max(-1.0) |> min(1.0)

  defp apply_media_attachment_updates(attachment, %{description: :unchanged, focus: nil}),
    do: attachment

  defp apply_media_attachment_updates(attachment, %{description: description, focus: focus}) do
    attachment
    |> put_media_attachment_description(description)
    |> put_media_attachment_focus(focus)
  end

  defp put_media_attachment_description(attachment, :unchanged), do: attachment

  defp put_media_attachment_description(attachment, description) when is_binary(description) do
    trimmed = String.trim(description)

    if Elektrine.Strings.present?(trimmed) do
      Map.put(attachment, "alt_text", trimmed)
    else
      Map.delete(attachment, "alt_text")
    end
  end

  defp put_media_attachment_description(attachment, nil), do: Map.delete(attachment, "alt_text")
  defp put_media_attachment_description(attachment, _description), do: attachment

  defp put_media_attachment_focus(attachment, nil), do: attachment
  defp put_media_attachment_focus(attachment, focus), do: Map.put(attachment, "focus", focus)

  defp put_media_attachment_at(attachments, index, attachment) do
    attachments
    |> pad_media_attachments(index)
    |> List.replace_at(index, attachment)
  end

  defp pad_media_attachments(attachments, index) do
    if length(attachments) > index do
      attachments
    else
      attachments ++ List.duplicate(%{}, index - length(attachments) + 1)
    end
  end

  defp put_media_attachment_alt_text(metadata, _index, %{description: :unchanged}), do: metadata

  defp put_media_attachment_alt_text(metadata, index, %{description: description})
       when is_binary(description) do
    trimmed = String.trim(description)
    alt_texts = Map.get(metadata, "alt_texts", %{})

    if Elektrine.Strings.present?(trimmed) do
      Map.put(metadata, "alt_texts", Map.put(alt_texts, to_string(index), trimmed))
    else
      Map.put(metadata, "alt_texts", Map.delete(alt_texts, to_string(index)))
    end
  end

  defp put_media_attachment_alt_text(metadata, index, %{description: nil}) do
    alt_texts = Map.get(metadata, "alt_texts", %{})
    Map.put(metadata, "alt_texts", Map.delete(alt_texts, to_string(index)))
  end

  defp put_media_attachment_alt_text(metadata, _index, _updates), do: metadata

  defp normalize_media_attachment_lookup_id(media_id) do
    media_id
    |> String.trim()
    |> URI.decode_www_form()
  rescue
    ArgumentError -> String.trim(media_id)
  end

  defp normalize_existing_media_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(fn
      attachment when is_map(attachment) ->
        Enum.reduce(attachment, %{}, fn {key, value}, acc ->
          if is_nil(value), do: acc, else: Map.put(acc, to_string(key), value)
        end)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_existing_media_attachments(_attachments), do: []

  defp normalize_media_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      normalized_key = to_string(key)

      normalized_value =
        if normalized_key == "attachments" do
          normalize_media_attachments(value)
        else
          value
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_media_metadata(_metadata), do: %{}

  defp normalize_media_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_media_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_media_attachments(_attachments), do: []

  defp normalize_media_attachment(attachment) when is_map(attachment) do
    normalized =
      Enum.reduce(attachment, %{}, fn {key, value}, acc ->
        if is_nil(value) do
          acc
        else
          Map.put(acc, to_string(key), value)
        end
      end)

    url = normalized["url"] || normalized["key"]
    mime_type = normalized["mime_type"] || normalized["content_type"]

    if is_binary(url) and is_binary(mime_type) do
      %{}
      |> maybe_put_media_attachment_text("id", normalized["id"] || media_attachment_id(url))
      |> maybe_put_media_attachment_text("url", url)
      |> maybe_put_media_attachment_text("mime_type", mime_type)
      |> maybe_put_media_attachment_text("filename", normalized["filename"])
      |> maybe_put_media_attachment_text("alt_text", normalized["alt_text"])
      |> maybe_put_media_attachment_text(
        "authorization",
        normalized["authorization"] || "public"
      )
      |> maybe_put_media_attachment_text("retention", normalized["retention"] || "origin")
      |> maybe_put_media_attachment_integer(
        "byte_size",
        normalized["byte_size"] || normalized["size"]
      )
      |> maybe_put_media_attachment_integer("width", normalized["width"])
      |> maybe_put_media_attachment_integer("height", normalized["height"])
      |> maybe_put_media_attachment_integer("duration_ms", normalized["duration_ms"])
    end
  end

  defp normalize_media_attachment(_attachment), do: nil

  defp media_attachment_id(url) when is_binary(url) do
    encoded_hash =
      :crypto.hash(:sha256, url)
      |> Base.url_encode64(padding: false)

    "attachment-#{encoded_hash}"
  end

  defp maybe_put_media_attachment_text(map, _key, nil), do: map

  defp maybe_put_media_attachment_text(map, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if Elektrine.Strings.present?(trimmed), do: Map.put(map, key, trimmed), else: map
  end

  defp maybe_put_media_attachment_text(map, _key, _value), do: map

  defp maybe_put_media_attachment_integer(map, key, value)
       when is_integer(value) and value >= 0 do
    Map.put(map, key, value)
  end

  defp maybe_put_media_attachment_integer(map, _key, _value), do: map

  defp maybe_merge_attachment_alt_texts(metadata, nil), do: metadata

  defp maybe_merge_attachment_alt_texts(metadata, alt_texts)
       when is_map(metadata) and is_map(alt_texts) and map_size(alt_texts) > 0 do
    case Map.get(metadata, "attachments") do
      attachments when is_list(attachments) ->
        merged_attachments =
          attachments
          |> Enum.with_index()
          |> Enum.map(fn {attachment, index} ->
            attachment
            |> normalize_media_metadata()
            |> maybe_put_attachment_alt_text(Map.get(alt_texts, to_string(index)))
          end)

        Map.put(metadata, "attachments", merged_attachments)

      _ ->
        metadata
    end
  end

  defp maybe_merge_attachment_alt_texts(metadata, _alt_texts), do: metadata

  defp maybe_put_attachment_alt_text(attachment, nil), do: attachment

  defp maybe_put_attachment_alt_text(attachment, alt_text)
       when is_map(attachment) and is_binary(alt_text) do
    trimmed = String.trim(alt_text)

    if Elektrine.Strings.present?(trimmed) do
      Map.put(attachment, "alt_text", trimmed)
    else
      attachment
    end
  end

  defp maybe_put_attachment_alt_text(attachment, _alt_text), do: attachment

  defp maybe_put_alt_texts(metadata, nil), do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts) when not is_map(alt_texts), do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts) when map_size(alt_texts) == 0, do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts), do: Map.put(metadata, "alt_texts", alt_texts)

  defp maybe_put_community_actor_uri(metadata, nil), do: metadata
  defp maybe_put_community_actor_uri(metadata, ""), do: metadata

  defp maybe_put_community_actor_uri(metadata, community_actor_uri)
       when is_binary(community_actor_uri) do
    normalized = String.trim(community_actor_uri)

    if not Elektrine.Strings.present?(normalized) || normalized in @public_audience_uris do
      metadata
    else
      Map.put(metadata, "community_actor_uri", normalized)
    end
  end

  defp maybe_put_community_actor_uri(metadata, _community_actor_uri), do: metadata

  defp maybe_put_category(attrs, nil), do: attrs
  defp maybe_put_category(attrs, category), do: Map.put(attrs, :category, category)

  defp maybe_process_message_hashtags(_message_id, []), do: :ok

  defp maybe_process_message_hashtags(message_id, hashtags) do
    HashtagExtractor.process_hashtags_for_message(message_id, hashtags)
  end

  defp maybe_federate_timeline_post(%Message{visibility: visibility} = message)
       when visibility in ["public", "followers"] do
    Async.start(fn ->
      preloaded = Repo.preload(message, :sender)
      Outbox.federate_post(preloaded)
    end)
  end

  defp maybe_federate_timeline_post(_message), do: :ok

  defp resolve_link_preview(urls) do
    case List.first(urls) do
      nil ->
        {nil, nil}

      url ->
        case FetchLinkPreviewWorker.enqueue(url) do
          {:ok, {:exists, preview}} -> {preview.id, preview.title}
          {:ok, _job} -> {nil, nil}
          _ -> {nil, nil}
        end
    end
  end

  defp build_timeline_post_attrs(%{
         user_id: user_id,
         validated_content: validated_content,
         media_urls: media_urls,
         visibility: visibility,
         post_type: post_type,
         opts: opts,
         conversation_id: conversation_id,
         extracted_urls: extracted_urls,
         extracted_hashtags: extracted_hashtags,
         link_preview_id: link_preview_id,
         validated_title: validated_title,
         auto_title: auto_title,
         base_media_metadata: base_media_metadata,
         alt_texts: alt_texts,
         community_actor_uri: community_actor_uri,
         category: category,
         primary_url: primary_url
       }) do
    final_title = validated_title || auto_title
    is_auto_title = is_nil(validated_title) and not is_nil(auto_title)
    media_metadata = build_media_metadata(base_media_metadata, alt_texts, community_actor_uri)

    %{
      conversation_id: conversation_id,
      sender_id: user_id,
      content: validated_content,
      message_type: if(Enum.empty?(media_urls), do: "text", else: "image"),
      media_urls: media_urls,
      media_metadata: media_metadata,
      visibility: visibility,
      post_type: post_type,
      extracted_urls: extracted_urls,
      extracted_hashtags: extracted_hashtags,
      link_preview_id: link_preview_id,
      reply_to_id: Keyword.get(opts, :reply_to_id),
      original_message_id: Keyword.get(opts, :original_message_id),
      shared_message_id: Keyword.get(opts, :shared_message_id),
      promoted_from: Keyword.get(opts, :promoted_from),
      share_type: Keyword.get(opts, :share_type),
      promoted_from_community_name: Keyword.get(opts, :promoted_from_community_name),
      promoted_from_community_hash: Keyword.get(opts, :promoted_from_community_hash),
      primary_url: primary_url,
      content_warning: Keyword.get(opts, :content_warning),
      sensitive: Keyword.get(opts, :sensitive, false),
      title: final_title,
      auto_title: is_auto_title
    }
    |> maybe_put_category(category)
  end

  defp persist_timeline_post(attrs, user_id, validated_content, extracted_hashtags) do
    case Message.changeset(%Message{}, attrs) |> Repo.insert() do
      {:ok, message} ->
        RateLimiter.record_timeline_post(user_id)
        maybe_process_message_hashtags(message.id, extracted_hashtags)
        message = %{message | like_count: 0, reply_count: 0, share_count: 0}
        notify_mentions(validated_content, user_id, message.id)
        Accounts.notify_subscribers_for_message(message)
        broadcast_timeline_post(message)
        maybe_federate_timeline_post(message)
        enqueue_home_feed_fanout(message.id)
        emit_post_created_webhook(message, user_id)
        reloaded_message = Repo.preload(message, [:link_preview, :hashtags, sender: :profile])
        {:ok, %{reloaded_message | like_count: 0, reply_count: 0, share_count: 0}}

      error ->
        error
    end
  end

  defp emit_post_created_webhook(message, user_id) do
    payload = %{
      post_id: message.id,
      conversation_id: message.conversation_id,
      post_type: message.post_type,
      visibility: message.visibility,
      title: message.title,
      content_preview: String.slice(message.content || "", 0, 280),
      inserted_at: message.inserted_at
    }

    _ = Elektrine.Developer.deliver_event(user_id, "post.created", payload)
    :ok
  rescue
    _ -> :ok
  end

  defp enqueue_home_feed_fanout(message_id) when is_integer(message_id) do
    _ = Elektrine.Social.HomeFeedFanoutWorker.enqueue(message_id)
    :ok
  rescue
    _ -> :ok
  end

  defp blocked_user_ids(nil), do: []
  defp blocked_user_ids(user_id), do: BlockedUsersCache.get_all_blocked_user_ids(user_id)

  defp apply_id_pagination(query, %{before_id: before_id} = pagination) do
    TimelinePagination.apply(query, %{pagination | before_id: before_id})
  end

  defp apply_id_order(query, :asc), do: TimelinePagination.order(query, :asc)

  defp apply_id_order(query, :desc), do: TimelinePagination.order(query, :desc)

  defp pagination_requested?(pagination), do: TimelinePagination.requested?(pagination)

  defp pagination_opts(opts, default_order \\ :desc),
    do: TimelinePagination.opts(opts, default_order)

  defp maybe_exclude_blocked_senders(query, []), do: query

  defp maybe_exclude_blocked_senders(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids)
  end

  defp maybe_exclude_blocked_senders_or_nil(query, []), do: query

  defp maybe_exclude_blocked_senders_or_nil(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids or is_nil(m.sender_id))
  end

  defp maybe_apply_viewer_timeline_policy(query, nil), do: maybe_exclude_blocked_instances(query)

  defp maybe_apply_viewer_timeline_policy(query, user_id) do
    query
    |> maybe_exclude_muted_senders(user_id)
    |> maybe_exclude_blocked_remote_actors(user_id)
    |> maybe_exclude_user_blocked_domains(user_id)
    |> maybe_exclude_blocked_instances()
  end

  defp maybe_exclude_muted_senders(query, user_id) do
    from(m in query,
      left_join: mute in UserMute,
      on: mute.muter_id == ^user_id and mute.muted_id == m.sender_id,
      where: is_nil(mute.id)
    )
  end

  defp maybe_exclude_blocked_remote_actors(query, user_id) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_remote_actor in UserBlock,
      on:
        blocked_remote_actor.user_id == ^user_id and blocked_remote_actor.block_type == "user" and
          blocked_remote_actor.blocked_uri == remote_actor.uri,
      where: is_nil(remote_actor.id) or is_nil(blocked_remote_actor.id)
    )
  end

  defp maybe_exclude_user_blocked_domains(query, user_id) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_domain in UserBlock,
      on:
        blocked_domain.user_id == ^user_id and blocked_domain.block_type == "domain" and
          (fragment("lower(?)", blocked_domain.blocked_uri) ==
             fragment("lower(?)", remote_actor.domain) or
             fragment(
               "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
               blocked_domain.blocked_uri,
               remote_actor.domain,
               blocked_domain.blocked_uri
             )),
      where: is_nil(remote_actor.id) or is_nil(blocked_domain.id)
    )
  end

  defp maybe_exclude_blocked_instances(query) do
    if blocked_instances_exist?() do
      from(m in query,
        left_join: remote_actor in assoc(m, :remote_actor),
        left_join: blocked_instance in Instance,
        on:
          blocked_instance.blocked == true and
            (fragment("lower(?)", blocked_instance.domain) ==
               fragment("lower(?)", remote_actor.domain) or
               fragment(
                 "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
                 blocked_instance.domain,
                 remote_actor.domain,
                 blocked_instance.domain
               )),
        where: is_nil(remote_actor.id) or is_nil(blocked_instance.id)
      )
    else
      query
    end
  end

  defp blocked_instances_exist? do
    Repo.exists?(from(i in Instance, where: i.blocked == true))
  end

  defp maybe_exclude_public_timeline_removed_instances(query) do
    if public_timeline_removed_instances_exist?() do
      from(m in query,
        left_join: remote_actor in assoc(m, :remote_actor),
        left_join: removed_instance in Instance,
        on:
          (removed_instance.silenced == true or
             removed_instance.federated_timeline_removal == true) and
            (fragment("lower(?)", removed_instance.domain) ==
               fragment("lower(?)", remote_actor.domain) or
               fragment(
                 "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
                 removed_instance.domain,
                 remote_actor.domain,
                 removed_instance.domain
               )),
        where: is_nil(remote_actor.id) or is_nil(removed_instance.id)
      )
    else
      query
    end
  end

  defp public_timeline_removed_instances_exist? do
    Repo.exists?(
      from(i in Instance, where: i.silenced == true or i.federated_timeline_removal == true)
    )
  end

  defp visibility_levels_for_viewer(user_id, viewer_id) do
    cond do
      viewer_id == user_id -> ["public", "followers", "friends", "private"]
      is_nil(viewer_id) -> ["public"]
      Friends.are_friends?(viewer_id, user_id) -> ["public", "followers", "friends"]
      Profiles.following?(viewer_id, user_id) -> ["public", "followers"]
      true -> ["public"]
    end
  end

  defp timeline_sender_visibility_filter(user_id, following_ids, friend_ids) do
    dynamic(
      [m],
      m.sender_id == ^user_id or
        (m.sender_id in ^following_ids and m.visibility in ["public", "unlisted", "followers"]) or
        (m.sender_id in ^friend_ids and m.visibility == "friends")
    )
  end

  defp public_timeline_scope_filter do
    dynamic(
      [m, c],
      (c.type == "timeline" and m.post_type == "post") or
        (is_nil(m.conversation_id) and m.federated == true)
    )
  end

  defp discussion_visibility_and_type_filter do
    dynamic([m], m.post_type in ^@discussion_post_types)
  end

  @doc """
  Gets or creates a user's timeline conversation.
  """
  def get_or_create_user_timeline(user_id) do
    # Check if user has a timeline conversation
    case Repo.get_by(Conversation, creator_id: user_id, type: "timeline") do
      nil ->
        # Create timeline conversation for this user
        {:ok, conversation} =
          %Conversation{}
          |> Conversation.changeset(%{
            name: "Timeline",
            type: "timeline",
            creator_id: user_id,
            is_public: true,
            allow_public_posts: true
          })
          |> Repo.insert()

        conversation

      conversation ->
        conversation
    end
  end

  # NOTE: increment_like_count/1 and decrement_like_count/1 moved to Elektrine.Social.Likes

  @doc """
  Increments the reply count for a message.
  """
  def increment_reply_count(message_id) do
    reconcile_reply_count(message_id, 1)

    # Also increment all ancestor posts in the thread
    increment_parent_counts(message_id)

    # Get the updated message to broadcast
    message = Repo.get!(Message, message_id) |> Repo.preload(:conversation)

    # Broadcast the update to various channels
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "message:#{message_id}",
      {:reply_count_updated, message_id, message.reply_count || 1}
    )

    # If it's a timeline post, broadcast to timeline channels
    # Federated posts don't have conversation loaded
    message_with_conversation = Repo.preload(message, :conversation)

    if message_with_conversation.conversation &&
         message_with_conversation.conversation.type == "timeline" do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "timeline:all",
        {:reply_count_updated, message_id, message.reply_count || 1}
      )

      # Broadcast to the post author's timeline (if local post)
      if message.sender_id do
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{message.sender_id}:timeline",
          {:reply_count_updated, message_id, message.reply_count || 1}
        )
      end
    end
  end

  defp reconcile_reply_count(message_id, delta) when delta in [-1, 1] do
    with %Message{} = message <- Repo.get(Message, message_id) do
      current_local_reply_count =
        from(m in Message,
          where: m.reply_to_id == ^message_id and is_nil(m.deleted_at),
          select: count(m.id)
        )
        |> Repo.one()

      previous_local_reply_count = max(current_local_reply_count - delta, 0)

      remote_baseline =
        message
        |> remote_reply_count_baseline()
        |> max(max((message.reply_count || 0) - previous_local_reply_count, 0))

      reply_count = remote_baseline + current_local_reply_count

      from(m in Message, where: m.id == ^message_id)
      |> Repo.update_all(set: [reply_count: reply_count])

      Elektrine.AppCache.invalidate_social_message(message_id)
    end
  end

  defp reconcile_reply_count(_, _), do: :ok

  defp remote_reply_count_baseline(%Message{} = message) do
    remote_count =
      message
      |> Map.get(:remote_reply_count)
      |> parse_non_negative_count()

    metadata_count =
      message
      |> Map.get(:media_metadata, %{})
      |> Map.get("original_reply_count")
      |> parse_non_negative_count()

    max(remote_count, metadata_count)
  end

  defp parse_non_negative_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0

  @doc """
  Broadcasts a timeline post to followers via PubSub.
  """
  def broadcast_timeline_post(message) do
    follower_ids =
      case message.visibility do
        visibility when visibility in ["public", "unlisted", "followers"] ->
          from(f in Follow,
            where: f.followed_id == ^message.sender_id,
            select: f.follower_id
          )
          |> Repo.all()

        "friends" ->
          Friends.list_friends(message.sender_id) |> Enum.map(& &1.id)

        _ ->
          []
      end

    # Broadcast to all followers using Task.async_stream for better performance
    Task.async_stream(
      follower_ids,
      fn follower_id ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{follower_id}:timeline",
          {:new_timeline_post, message}
        )
      end,
      max_concurrency: 10,
      ordered: false,
      timeout: 5000
    )
    |> Stream.run()

    # Also broadcast to global timeline for public posts
    if message.visibility == "public" do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "timeline:public",
        {:new_public_post, message}
      )
    end
  end

  # NOTE: broadcast_like_event/2 moved to Elektrine.Social.Likes

  @doc """
  Get suggested users to follow based on various factors.
  """
  def get_suggested_follows(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    following_ids = list_following_ids(user_id)
    dismissed_ids = list_dismissed_suggested_follow_ids(user_id)

    suggestions =
      suggested_active_users(user_id, following_ids, limit) ++
        suggested_mutual_users(user_id, following_ids, limit) ++
        suggested_popular_users(user_id, following_ids, limit)

    suggestions
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id in dismissed_ids))
    |> Enum.take(limit)
    |> hydrate_suggested_follow_users()
  end

  @doc """
  Dismisses an account from a user's follow suggestions.
  """
  def dismiss_suggested_follow(user_id, suggested_user_id)
      when is_integer(user_id) and is_integer(suggested_user_id) and user_id != suggested_user_id do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SuggestedAccountDismissal{}
    |> SuggestedAccountDismissal.changeset(%{
      user_id: user_id,
      suggested_user_id: suggested_user_id,
      dismissed_at: now
    })
    |> Repo.insert(
      on_conflict: [set: [dismissed_at: now, updated_at: now]],
      conflict_target: [:user_id, :suggested_user_id]
    )
  end

  def dismiss_suggested_follow(_user_id, _suggested_user_id), do: {:error, :invalid_suggestion}

  defp list_dismissed_suggested_follow_ids(user_id) do
    from(dismissal in SuggestedAccountDismissal,
      where: dismissal.user_id == ^user_id,
      select: dismissal.suggested_user_id
    )
    |> Repo.all()
  end

  defp list_following_ids(user_id) do
    from(f in Follow, where: f.follower_id == ^user_id, select: f.followed_id)
    |> Repo.all()
  end

  defp suggested_active_users(user_id, following_ids, limit) do
    from(m in Message,
      join: u in User,
      on: u.id == m.sender_id,
      where:
        m.post_type == "post" and
          m.visibility in ["public", "followers"] and
          m.sender_id != ^user_id and
          m.sender_id not in ^following_ids and
          m.inserted_at > ago(7, "day") and
          not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      order_by: [desc: count(m.id), desc: max(m.inserted_at)],
      limit: ^(limit * 2),
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        post_count: count(m.id),
        reason: "Active poster"
      }
    )
    |> Repo.all()
  end

  defp suggested_mutual_users(user_id, following_ids, limit) do
    from(f1 in Follow,
      join: f2 in Follow,
      on: f1.followed_id == f2.follower_id,
      join: u in User,
      on: u.id == f2.followed_id,
      where:
        f1.follower_id == ^user_id and
          f2.followed_id != ^user_id and
          f2.followed_id not in ^following_ids and
          not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      order_by: [desc: count(f2.id)],
      limit: ^limit,
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        mutual_count: count(f2.id),
        reason: "Followed by people you follow"
      }
    )
    |> Repo.all()
  end

  defp suggested_popular_users(user_id, following_ids, limit) do
    from(u in User,
      left_join: f in Follow,
      on: f.followed_id == u.id,
      left_join: _p in assoc(u, :profile),
      where: u.id != ^user_id and u.id not in ^following_ids and not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      having: count(f.id) > 0,
      order_by: [desc: count(f.id)],
      limit: ^limit,
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        follower_count: count(f.id),
        reason: "Popular user"
      }
    )
    |> Repo.all()
  end

  defp hydrate_suggested_follow_users([]), do: []

  defp hydrate_suggested_follow_users(suggestions) do
    ids = Enum.map(suggestions, & &1.id)

    users_by_id =
      User
      |> where([user], user.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(suggestions, fn suggestion ->
      Map.put(suggestion, :user, Map.get(users_by_id, suggestion.id))
    end)
  end

  # Add missing helper function for timeline LiveView
  # Uses abbreviated format (5m, 2h, 3d) - delegates to shared TextHelpers
  def time_ago_in_words(datetime), do: Elektrine.TextHelpers.time_ago_short(datetime)

  ## Discussion Posts

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

  # NOTE: Voting functions are now in Elektrine.Social.Votes
  # and delegated at the top of this module.

  ## Cross-Context Content Promotion System

  @doc """
  Promotes a chat message to timeline as a public post.
  This enables the natural progression from private insights to public sharing.
  """
  def promote_message_to_timeline(message_id, user_id, opts \\ []) do
    # Check cross-context promotion rate limit
    if RateLimiter.can_promote_cross_context?(user_id) do
      visibility = Keyword.get(opts, :visibility, "public")

      # Get the original message
      message =
        from(m in Message,
          where: m.id == ^message_id and m.sender_id == ^user_id,
          preload: [:sender, :conversation]
        )
        |> Repo.one()

      promote_message_to_timeline_post(message, user_id, visibility)
    else
      {:error, :rate_limited}
    end
  end

  defp promote_message_to_timeline_post(nil, _user_id, _visibility), do: {:error, :not_found}

  defp promote_message_to_timeline_post(%Message{deleted_at: deleted_at}, _user_id, _visibility)
       when not is_nil(deleted_at),
       do: {:error, :message_deleted}

  defp promote_message_to_timeline_post(%Message{} = msg, user_id, visibility) do
    content_with_hash = timeline_promotion_content(msg)

    case create_timeline_post(user_id, content_with_hash,
           visibility: visibility,
           original_message_id: msg.id,
           promoted_from: "chat"
         ) do
      {:ok, timeline_post} ->
        RateLimiter.record_cross_promotion(user_id)
        {:ok, timeline_post}

      error ->
        error
    end
  end

  defp timeline_promotion_content(msg) do
    content = String.trim(msg.content)

    case msg.conversation.hash do
      nil -> content
      hash -> "#{content}\n\n<!-- hash:#{hash} name:#{msg.conversation.name} -->"
    end
  end

  @doc """
  Unified cross-posting function for sharing content between platforms.
  Supports sharing from timeline, discussions, and chat to any other platform.
  """
  def cross_post_to_discussion(source_message_id, user_id, community_id, title, comment \\ "") do
    case fetch_cross_post_source(source_message_id) do
      nil ->
        {:error, :not_found}

      %Message{} = source ->
        with :ok <- ensure_conversation_member(community_id, user_id),
             {:ok, discussion_message} <-
               Messaging.create_text_message(community_id, user_id, comment || "") do
          discussion_message
          |> Message.changeset(%{
            post_type: "discussion",
            title: title,
            shared_message_id: source_message_id,
            share_type: "cross_post",
            promoted_from: get_source_type(source),
            metadata: %{
              "title" => title,
              "cross_post_source" => %{
                "id" => source.id,
                "type" => get_source_type(source),
                "name" => get_source_name(source)
              }
            }
          })
          |> Repo.update()
        else
          {:error, :not_member} -> {:error, :not_member}
          error -> error
        end
    end
  end

  defp fetch_cross_post_source(source_message_id) do
    from(m in Message,
      where: m.id == ^source_message_id,
      preload: [:sender, :conversation, :link_preview]
    )
    |> Repo.one()
  end

  defp ensure_conversation_member(conversation_id, user_id) do
    case Messaging.get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :not_member}
      _member -> :ok
    end
  end

  defp get_source_type(%Message{conversation: %{type: "timeline"}}), do: "timeline"
  defp get_source_type(%Message{conversation: %{type: "community"}}), do: "discussion"
  defp get_source_type(%Message{conversation: %{type: "dm"}}), do: "chat"
  defp get_source_type(%Message{conversation: %{type: "group"}}), do: "chat"
  defp get_source_type(%Message{conversation: %{type: "channel"}}), do: "chat"
  defp get_source_type(_), do: "unknown"

  defp get_source_name(%Message{conversation: %{type: "timeline"}}), do: "Timeline"
  defp get_source_name(%Message{conversation: %{type: "community", name: name}}), do: name
  defp get_source_name(%Message{conversation: %{type: "dm"}}), do: "Chat"
  defp get_source_name(%Message{conversation: %{type: "group"}}), do: "Chat"
  defp get_source_name(%Message{conversation: %{type: "channel"}}), do: "Chat"
  defp get_source_name(_), do: ""

  @doc """
  Cross-post content to a chat conversation
  """
  def cross_post_to_chat(source_message_id, user_id, conversation_id, comment \\ "") do
    source_message =
      from(m in Message, where: m.id == ^source_message_id, preload: [:sender, :conversation])
      |> Repo.one()

    case source_message do
      nil ->
        {:error, :not_found}

      %Message{} = source ->
        message_content = minimal_share_comment(comment)

        case Messaging.create_text_message(conversation_id, user_id, message_content) do
          {:ok, message} ->
            message
            |> Message.changeset(%{
              shared_message_id: source_message_id,
              share_type: "cross_post",
              promoted_from: get_source_type(source)
            })
            |> Repo.update()

          error ->
            error
        end
    end
  end

  defp minimal_share_comment(comment) when comment in ["", nil], do: " "
  defp minimal_share_comment(comment), do: comment

  @doc """
  Promotes a timeline post to a community discussion.
  This enables moving viral content to deeper discussion contexts.
  """
  def promote_timeline_to_discussion(message_id, user_id, community_id, opts \\ []) do
    discussion_title = Keyword.get(opts, :title)

    # Get the original timeline post
    timeline_post =
      from(m in Message,
        where: m.id == ^message_id and m.post_type == "post",
        preload: [:sender, :conversation, :link_preview]
      )
      |> Repo.one()

    case timeline_post do
      nil ->
        {:error, :not_found}

      %Message{} = post ->
        with :ok <- ensure_conversation_member(community_id, user_id),
             {:ok, discussion_message} <- Messaging.create_text_message(community_id, user_id, "") do
          title = discussion_title || "Discussion: #{String.slice(post.content, 0, 50)}..."

          discussion_message
          |> Message.changeset(%{
            post_type: "discussion",
            shared_message_id: post.id,
            share_type: "cross_post",
            promoted_from: "timeline",
            title: title
          })
          |> Repo.update()
        else
          {:error, :not_member} -> {:error, :not_member}
          error -> error
        end
    end
  end

  @doc """
  Creates a private DM conversation from public content for deeper discussion.
  This enables moving public conversations to private contexts.
  """
  def discuss_privately(message_id, initiator_user_id, target_user_id, opts \\ []) do
    intro_message =
      Keyword.get(opts, :intro_message, "Hey, saw your post and wanted to discuss this further!")

    # Get the original message for context
    original_message =
      from(m in Message,
        where: m.id == ^message_id,
        preload: [:sender, :conversation]
      )
      |> Repo.one()

    case original_message do
      nil ->
        {:error, :not_found}

      %Message{} = msg ->
        with {:ok, dm_conversation} <-
               Messaging.create_dm_conversation(initiator_user_id, target_user_id),
             {:ok, dm_message} <-
               Messaging.create_text_message(dm_conversation.id, initiator_user_id, intro_message) do
          dm_message
          |> Message.changeset(%{
            shared_message_id: message_id,
            share_type: "cross_post",
            promoted_from: get_source_type(msg)
          })
          |> Repo.update()
        else
          error -> error
        end
    end
  end

  @doc """
  Shares content from one context to timeline with proper attribution.
  Generic function for cross-context sharing.
  """
  def share_to_timeline(source_message_id, user_id, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, "followers")
    comment = Keyword.get(opts, :comment, "")

    # Get source message
    source =
      from(m in Message,
        where: m.id == ^source_message_id,
        preload: [:sender, :conversation, :remote_actor]
      )
      |> Repo.one()

    case source do
      nil ->
        {:error, :not_found}

      %Message{} = msg ->
        result =
          create_timeline_post(
            user_id,
            comment || "",
            Keyword.merge(
              [
                visibility: visibility,
                shared_message_id: msg.id,
                share_type: share_type_for_message(msg),
                promoted_from: promoted_from_for_message(msg)
              ],
              share_extra_attrs(msg)
            )
          )

        maybe_federate_announce_share(result, msg, user_id)
    end
  end

  defp share_type_for_message(%Message{federated: true}), do: "federated_boost"
  defp share_type_for_message(msg), do: determine_share_type(msg)

  defp promoted_from_for_message(%Message{federated: true}), do: "fediverse"
  defp promoted_from_for_message(msg), do: determine_promoted_from(msg)

  defp share_extra_attrs(%Message{conversation: %{type: "community", hash: hash, name: name}})
       when is_binary(hash) do
    [promoted_from_community_hash: hash, promoted_from_community_name: name]
  end

  defp share_extra_attrs(_), do: []

  defp maybe_federate_announce_share({:ok, _share_post} = result, %Message{} = msg, user_id) do
    if msg.federated && msg.activitypub_id do
      Async.start(fn ->
        Outbox.federate_announce(msg.id, user_id)
      end)
    end

    result
  end

  defp maybe_federate_announce_share(error, _msg, _user_id), do: error

  @doc """
  Links a discussion post to a timeline post for unified commenting.
  This enables shared comment threads across contexts.
  """
  def link_discussion_to_timeline(discussion_id, timeline_post_id, user_id) do
    # Get both posts
    with {:ok, discussion} <- get_message(discussion_id),
         {:ok, timeline_post} <- get_message(timeline_post_id),
         true <- discussion.sender_id == user_id || timeline_post.sender_id == user_id do
      # Link discussion as a "promotion" of the timeline post
      discussion
      |> Message.changeset(%{
        original_message_id: timeline_post_id,
        promoted_from: "timeline"
      })
      |> Repo.update()
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc """
  Gets unified replies for a post across all contexts.
  """
  def get_unified_replies(post_id) do
    from(m in Message,
      where:
        m.reply_to_id == ^post_id and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      order_by: [desc: m.like_count, desc: m.score, asc: m.inserted_at],
      preload: [sender: [:profile], conversation: []]
    )
    |> Repo.all()
  end

  defp get_message(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  # Private helper functions for content promotion

  defp determine_share_type(%Message{conversation: %{type: "community"}}), do: "discussion_share"
  defp determine_share_type(%Message{post_type: "post"}), do: "timeline_reshare"
  defp determine_share_type(_), do: "general_share"

  defp determine_promoted_from(%Message{conversation: %{type: "community"}}), do: "discussion"
  defp determine_promoted_from(%Message{conversation: %{type: "timeline"}}), do: "timeline"
  defp determine_promoted_from(%Message{promoted_from: "timeline_reply"}), do: "timeline"
  defp determine_promoted_from(%Message{post_type: "post"}), do: "timeline"
  defp determine_promoted_from(%Message{conversation: %{type: "dm"}}), do: "chat"
  defp determine_promoted_from(%Message{conversation: %{type: "group"}}), do: "chat"
  defp determine_promoted_from(%Message{conversation: %{type: "channel"}}), do: "chat"
  defp determine_promoted_from(_), do: "chat"

  # Security helper functions

  defp rate_limit_to_ok(true), do: :ok
  defp rate_limit_to_ok(false), do: {:error, :rate_limited}

  defp get_user_with_permissions(user_id) do
    case Accounts.get_user!(user_id) do
      user -> {:ok, user}
    end
  rescue
    Ecto.NoResultsError -> {:error, :user_not_found}
  end

  defp validate_title_if_present(nil), do: {:ok, nil}
  defp validate_title_if_present(""), do: {:ok, nil}

  defp validate_title_if_present(title) when is_binary(title) do
    # Treat empty/whitespace titles as nil (optional)
    if Elektrine.Strings.present?(title) do
      case ContentValidator.validate_title(title) do
        {:ok, validated} -> {:ok, validated}
        error -> error
      end
    else
      {:ok, nil}
    end
  end

  # Allow empty content if media is present
  defp validate_content_or_allow_empty(content, media_urls) do
    if not Elektrine.Strings.present?(content) && !Enum.empty?(media_urls) do
      # Media-only post, allow empty content
      {:ok, ""}
    else
      # Regular validation
      ContentValidator.validate_content(content, :timeline)
    end
  end

  @doc """
  Creates notifications for @mentions in posts.
  """
  def notify_mentions(content, sender_id, message_id) do
    mentions = Mentions.extract_local_mentions(content)

    # Get sender info
    sender = Accounts.get_user!(sender_id)

    Enum.each(mentions, fn mention ->
      maybe_notify_mention(mention.username, sender, sender_id, message_id)
    end)
  end

  defp maybe_notify_mention(username, sender, sender_id, message_id) do
    case Accounts.get_user_by_username_or_handle(username) do
      %{} = mentioned_user ->
        maybe_create_mention_notification(mentioned_user, sender, sender_id, message_id)

      _ ->
        :ok
    end
  end

  defp maybe_create_mention_notification(
         %{id: id} = mentioned_user,
         sender,
         sender_id,
         message_id
       )
       when id != sender_id do
    if Map.get(mentioned_user, :notify_on_mention, true) do
      Notifications.create_notification(%{
        user_id: mentioned_user.id,
        actor_id: sender_id,
        type: "mention",
        title: "@#{sender.handle || sender.username} mentioned you",
        body: "You were mentioned in a post",
        url: "/timeline#post-#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "normal"
      })
    end
  end

  defp maybe_create_mention_notification(_mentioned_user, _sender, _sender_id, _message_id),
    do: :ok

  # Recursively increment reply counts for all parent posts
  defp increment_parent_counts(message_id) do
    import Ecto.Query

    # Build a list of all parent IDs by following the reply chain
    parent_ids = build_parent_chain(message_id, [])

    # Increment all parents in a single update per parent
    Enum.each(parent_ids, fn parent_id ->
      reconcile_reply_count(parent_id, 1)
    end)
  end

  # Helper to build the complete parent chain without recursion
  defp build_parent_chain(message_id, acc) do
    case from(m in Message, where: m.id == ^message_id, select: m.reply_to_id) |> Repo.one() do
      nil -> acc
      parent_id -> build_parent_chain(parent_id, [parent_id | acc])
    end
  end

  ## Poll System

  alias Elektrine.Social.{Poll, PollOption, PollVote}

  @doc """
  Creates a poll for a discussion post.
  """
  def create_poll(message_id, question, options, opts \\ []) do
    closes_at = Keyword.get(opts, :closes_at)
    allow_multiple = Keyword.get(opts, :allow_multiple, false)
    hide_totals = Keyword.get(opts, :hide_totals, false)
    options = normalize_poll_options(options)

    with :ok <- validate_poll_options(options),
         :ok <- validate_poll_expiration(closes_at) do
      Repo.transaction(fn ->
        create_poll_transaction(
          message_id,
          question,
          closes_at,
          allow_multiple,
          hide_totals,
          options
        )
      end)
    end
  end

  defp create_poll_transaction(
         message_id,
         question,
         closes_at,
         allow_multiple,
         hide_totals,
         options
       ) do
    case insert_poll(message_id, question, closes_at, allow_multiple, hide_totals) do
      {:ok, poll} ->
        poll_options = insert_poll_options(poll.id, options)
        %{poll | options: poll_options}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_poll(message_id, question, closes_at, allow_multiple, hide_totals) do
    poll_attrs = %{
      message_id: message_id,
      question: question,
      closes_at: closes_at,
      allow_multiple: allow_multiple,
      hide_totals: hide_totals
    }

    %Poll{}
    |> Poll.changeset(poll_attrs)
    |> Repo.insert()
  end

  defp insert_poll_options(poll_id, options) do
    options
    |> Enum.with_index()
    |> Enum.map(fn {option_text, position} ->
      option_attrs = %{poll_id: poll_id, option_text: option_text, position: position}

      case %PollOption{} |> PollOption.changeset(option_attrs) |> Repo.insert() do
        {:ok, poll_option} -> poll_option
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Votes on a poll option.
  """
  def vote_on_poll(poll_id, option_id, user_id) do
    poll = Repo.get!(Poll, poll_id) |> Repo.preload([:options, :message])

    with :ok <- validate_poll_vote_target(poll, option_id, user_id) do
      existing_votes = list_poll_votes_for_user(poll_id, user_id)
      result = apply_poll_vote(poll, poll_id, option_id, user_id, existing_votes)
      finalize_poll_vote_result(result, poll, option_id, user_id)
    end
  end

  defp validate_poll_vote_target(poll, option_id, user_id) do
    cond do
      Poll.closed?(poll) -> {:error, :poll_closed}
      poll.message && poll.message.sender_id == user_id -> {:error, :self_vote}
      not Enum.any?(poll.options, &(&1.id == option_id)) -> {:error, :invalid_option}
      true -> :ok
    end
  end

  defp list_poll_votes_for_user(poll_id, user_id) do
    from(v in PollVote, where: v.poll_id == ^poll_id and v.user_id == ^user_id)
    |> Repo.all()
  end

  defp apply_poll_vote(_poll, poll_id, option_id, user_id, []),
    do: create_poll_vote(poll_id, option_id, user_id)

  defp apply_poll_vote(
         %Poll{allow_multiple: false},
         _poll_id,
         option_id,
         _user_id,
         existing_votes
       ) do
    existing_vote = List.first(existing_votes)

    if existing_vote.option_id == option_id,
      do: remove_poll_vote(existing_vote),
      else: change_poll_vote(existing_vote, option_id)
  end

  defp apply_poll_vote(%Poll{allow_multiple: true}, poll_id, option_id, user_id, existing_votes) do
    case Enum.find(existing_votes, &(&1.option_id == option_id)) do
      nil -> create_poll_vote(poll_id, option_id, user_id)
      existing_vote -> remove_poll_vote(existing_vote)
    end
  end

  defp finalize_poll_vote_result({:ok, vote}, poll, option_id, user_id) do
    maybe_federate_poll_vote(poll, option_id, user_id)
    {:ok, vote}
  end

  defp finalize_poll_vote_result(other, _poll, _option_id, _user_id), do: other

  def get_poll(poll_id) do
    Poll
    |> Repo.get(poll_id)
    |> case do
      %Poll{} = poll ->
        {:ok, Repo.preload(poll, [:options, message: [:sender, :remote_actor]])}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def set_poll_votes(poll_id, option_ids, user_id)
      when is_list(option_ids) and is_integer(user_id) do
    with {:ok, %Poll{} = poll} <- get_poll(poll_id),
         normalized_option_ids <- normalize_poll_vote_option_ids(option_ids),
         :ok <- validate_poll_vote_set(poll, normalized_option_ids, user_id) do
      Repo.transaction(fn ->
        existing_votes = list_poll_votes_for_user(poll.id, user_id)
        existing_option_ids = Enum.map(existing_votes, & &1.option_id)
        desired_option_ids = normalized_poll_vote_set(poll, normalized_option_ids)
        remove_stale_poll_votes(existing_votes, desired_option_ids)

        inserted_votes =
          insert_missing_poll_votes(poll.id, desired_option_ids -- existing_option_ids, user_id)

        refresh_poll_counts(poll.id, existing_option_ids ++ desired_option_ids)
        Enum.each(inserted_votes, &maybe_federate_poll_vote(poll, &1.option_id, user_id))

        Poll
        |> Repo.get!(poll.id)
        |> Repo.preload([:options, message: [:sender, :remote_actor]])
      end)
    end
  end

  def set_poll_votes(_poll_id, _option_ids, _user_id), do: {:error, :invalid_vote}

  def clear_poll_votes(poll_id, user_id) when is_integer(user_id) do
    with {:ok, %Poll{} = poll} <- get_poll(poll_id) do
      Repo.transaction(fn ->
        existing_votes = list_poll_votes_for_user(poll.id, user_id)
        remove_stale_poll_votes(existing_votes, [])
        refresh_poll_counts(poll.id, Enum.map(existing_votes, & &1.option_id))

        Poll
        |> Repo.get!(poll.id)
        |> Repo.preload([:options, message: [:sender, :remote_actor]])
      end)
    end
  end

  def clear_poll_votes(_poll_id, _user_id), do: {:error, :not_found}

  defp normalize_poll_vote_option_ids(option_ids) do
    option_ids
    |> List.wrap()
    |> Enum.map(&parse_poll_vote_option_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_poll_vote_option_id(value) when is_integer(value) and value > 0, do: value

  defp parse_poll_vote_option_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_poll_vote_option_id(_value), do: nil

  defp validate_poll_vote_set(%Poll{} = poll, option_ids, user_id) do
    valid_option_ids = MapSet.new(Enum.map(poll.options || [], & &1.id))

    cond do
      option_ids == [] ->
        {:error, :invalid_vote}

      Poll.closed?(poll) ->
        {:error, :poll_closed}

      poll.message && poll.message.sender_id == user_id ->
        {:error, :self_vote}

      Enum.any?(option_ids, &(not MapSet.member?(valid_option_ids, &1))) ->
        {:error, :invalid_option}

      not poll.allow_multiple and length(option_ids) > 1 ->
        {:error, :multiple_votes_not_allowed}

      true ->
        :ok
    end
  end

  defp normalized_poll_vote_set(%Poll{allow_multiple: true}, option_ids), do: option_ids
  defp normalized_poll_vote_set(%Poll{}, [option_id | _]), do: [option_id]

  defp remove_stale_poll_votes(existing_votes, desired_option_ids) do
    desired_option_ids = MapSet.new(desired_option_ids)

    existing_votes
    |> Enum.reject(&MapSet.member?(desired_option_ids, &1.option_id))
    |> Enum.each(&Repo.delete!/1)
  end

  defp insert_missing_poll_votes(poll_id, option_ids, user_id) do
    Enum.map(option_ids, fn option_id ->
      %PollVote{}
      |> PollVote.changeset(%{poll_id: poll_id, option_id: option_id, user_id: user_id})
      |> Repo.insert!()
    end)
  end

  defp refresh_poll_counts(_poll_id, []), do: :ok

  defp refresh_poll_counts(poll_id, option_ids) do
    option_ids
    |> Enum.uniq()
    |> Enum.each(&update_poll_counts(poll_id, &1))
  end

  # Federates poll vote to remote instance if applicable
  defp maybe_federate_poll_vote(poll, option_id, user_id) do
    message = poll.message || Repo.get(Message, poll.message_id)

    with %Message{federated: true} = message <- message,
         option when not is_nil(option) <- Enum.find(poll.options, &(&1.id == option_id)) do
      preloaded_message = Repo.preload(message, :remote_actor)
      user = Accounts.get_user!(user_id)

      Async.start(fn ->
        Outbox.federate_poll_vote(poll, option, user, preloaded_message)
      end)
    end
  end

  @doc """
  Gets poll results with vote counts and percentages.
  """
  def get_poll_results(poll_id) do
    poll =
      Repo.get!(Poll, poll_id)
      |> Repo.preload(:options)

    options_with_votes =
      Enum.map(poll.options, fn option ->
        vote_count = option.vote_count

        percentage =
          if poll.total_votes > 0 do
            Float.round(vote_count / poll.total_votes * 100, 1)
          else
            0.0
          end

        %{
          id: option.id,
          text: option.option_text,
          vote_count: vote_count,
          percentage: percentage,
          position: option.position
        }
      end)
      |> Enum.sort_by(& &1.position)

    %{
      poll_id: poll.id,
      question: poll.question,
      total_votes: poll.total_votes,
      closes_at: poll.closes_at,
      allow_multiple: poll.allow_multiple,
      is_open: Poll.open?(poll),
      options: options_with_votes
    }
  end

  @doc """
  Gets user's votes on a poll.
  """
  def get_user_poll_votes(poll_id, user_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and v.user_id == ^user_id,
      select: v.option_id
    )
    |> Repo.all()
  end

  # Private poll helper functions

  defp create_poll_vote(poll_id, option_id, user_id) do
    case %PollVote{}
         |> PollVote.changeset(%{
           poll_id: poll_id,
           option_id: option_id,
           user_id: user_id
         })
         |> Repo.insert() do
      {:ok, vote} ->
        update_poll_counts(poll_id, option_id)
        {:ok, vote}

      error ->
        error
    end
  end

  defp remove_poll_vote(vote) do
    case Repo.delete(vote) do
      {:ok, deleted_vote} ->
        update_poll_counts(deleted_vote.poll_id, deleted_vote.option_id)
        {:ok, deleted_vote}

      error ->
        error
    end
  end

  defp change_poll_vote(vote, new_option_id) do
    old_option_id = vote.option_id

    case vote
         |> PollVote.changeset(%{option_id: new_option_id})
         |> Repo.update() do
      {:ok, updated_vote} ->
        # Decrement old option, increment new option
        update_poll_counts(vote.poll_id, old_option_id)
        update_poll_counts(vote.poll_id, new_option_id)
        {:ok, updated_vote}

      error ->
        error
    end
  end

  defp update_poll_counts(poll_id, option_id) do
    # Recalculate option vote count
    option_vote_count =
      from(v in PollVote,
        where: v.option_id == ^option_id,
        select: count(v.id)
      )
      |> Repo.one()

    from(o in PollOption, where: o.id == ^option_id)
    |> Repo.update_all(set: [vote_count: option_vote_count])

    # Recalculate total poll votes
    total_votes =
      from(v in PollVote,
        where: v.poll_id == ^poll_id,
        select: count(v.id)
      )
      |> Repo.one()

    voters_count =
      from(v in PollVote,
        where: v.poll_id == ^poll_id,
        select: count(fragment("distinct ?", v.user_id))
      )
      |> Repo.one()

    from(p in Poll, where: p.id == ^poll_id)
    |> Repo.update_all(set: [total_votes: total_votes, voters_count: voters_count])

    # Broadcast poll update
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "poll:#{poll_id}",
      {:poll_updated, poll_id}
    )
  end

  defp normalize_poll_options(options) when is_list(options) do
    options
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_poll_options(_), do: []

  defp validate_poll_options(options) do
    cond do
      length(options) < 2 ->
        {:error, "Poll must have at least 2 options"}

      length(options) > 4 ->
        {:error, "Poll can have at most 4 options"}

      Enum.any?(options, &(String.length(&1) > 50)) ->
        {:error, "Poll options must be at most 50 characters"}

      Enum.uniq_by(options, &String.downcase/1) |> length() != length(options) ->
        {:error, "Poll options must be unique"}

      true ->
        :ok
    end
  end

  defp validate_poll_expiration(nil), do: :ok

  defp validate_poll_expiration(%DateTime{} = closes_at) do
    seconds_until_close = DateTime.diff(closes_at, DateTime.utc_now(), :second)

    cond do
      seconds_until_close < 300 -> {:error, "Poll duration must be at least 5 minutes"}
      seconds_until_close > 31 * 24 * 60 * 60 -> {:error, "Poll duration must be at most 1 month"}
      true -> :ok
    end
  end

  defp validate_poll_expiration(_), do: {:error, "Invalid poll expiration"}

  # NOTE: Post View Tracking functions are now in Elektrine.Social.Views
  # These are delegated at the top of this module.

  ## ActivityPub Federation

  @doc """
  Gets federated timeline for a user (posts from remote users they follow).
  """
  def get_federated_timeline(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()
    remote_actor_ids = list_remote_actor_ids(user_id)

    case remote_actor_ids do
      [] ->
        []

      _ ->
        remote_actor_ids
        |> federated_timeline_query(limit, preloads)
        |> maybe_apply_viewer_timeline_policy(user_id)
        |> apply_id_pagination(pagination)
        |> apply_id_order(pagination.order)
        |> Repo.all()
    end
  end

  @doc """
  Gets combined timeline (local + federated posts from followed users).
  """
  def get_combined_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    search_query = Keyword.get(opts, :search_query)
    preloads = MessagingMessages.timeline_feed_preloads()

    case cached_combined_feed_page(user_id, limit, pagination, search_query, preloads) do
      posts when is_list(posts) and length(posts) >= limit ->
        posts

      _ ->
        posts =
          user_id
          |> query_combined_feed(limit * 2, pagination, search_query, preloads)
          |> then(&FeedPolicy.filter_home_posts(user_id, &1))
          |> Enum.take(limit)

        maybe_cache_combined_feed_page(user_id, posts, pagination, search_query)
        posts
    end
  end

  defp query_combined_feed(user_id, limit, pagination, search_query, preloads) do
    remote_actor_ids = list_remote_actor_ids(user_id)
    following_ids = get_following_user_ids(user_id)
    all_blocked_ids = blocked_user_ids(user_id)

    local_query =
      following_ids
      |> local_combined_feed_query(all_blocked_ids)
      |> maybe_apply_timeline_search(search_query)

    federated_query =
      remote_actor_ids
      |> maybe_federated_combined_query()
      |> maybe_apply_timeline_search(search_query)

    hashtag_query =
      user_id
      |> maybe_followed_hashtag_combined_query(all_blocked_ids)
      |> maybe_apply_timeline_search(search_query)

    local_query
    |> combined_feed_query([federated_query, hashtag_query], limit, preloads)
    |> maybe_apply_viewer_timeline_policy(user_id)
    |> apply_id_pagination(pagination)
    |> apply_id_order(pagination.order)
    |> Repo.all()
  end

  defp cached_combined_feed_page(user_id, limit, pagination, search_query, preloads) do
    if cacheable_combined_feed_page?(pagination, search_query) do
      ids = HomeFeedCache.get(user_id) |> Enum.take(limit * 3)

      if length(ids) >= limit do
        posts =
          from(m in Message,
            where: m.id in ^ids,
            where: is_nil(m.deleted_at) and m.is_draft != true,
            preload: ^preloads
          )
          |> maybe_apply_viewer_timeline_policy(user_id)
          |> Repo.all()
          |> order_posts_by_ids(ids)
          |> then(&FeedPolicy.filter_home_posts(user_id, &1))
          |> Enum.take(limit)

        if length(posts) >= limit, do: posts, else: nil
      end
    end
  end

  defp maybe_cache_combined_feed_page(user_id, posts, pagination, search_query) do
    cond do
      cacheable_combined_feed_page?(pagination, search_query) ->
        HomeFeedCache.put(user_id, Enum.map(posts, & &1.id))

      appendable_combined_feed_page?(pagination, search_query) ->
        HomeFeedCache.append(user_id, Enum.map(posts, & &1.id))

      true ->
        :ok
    end

    :ok
  end

  defp cacheable_combined_feed_page?(pagination, search_query) do
    pagination_requested?(pagination) == false and
      not Elektrine.Strings.present?(search_query)
  end

  defp appendable_combined_feed_page?(%{before_id: before_id, order: :desc}, search_query)
       when is_integer(before_id) do
    not Elektrine.Strings.present?(search_query)
  end

  defp appendable_combined_feed_page?(_pagination, _search_query), do: false

  defp order_posts_by_ids(posts, ids) do
    positions = ids |> Enum.with_index() |> Map.new()

    Enum.sort_by(posts, fn post -> Map.get(positions, post.id, length(ids)) end)
  end

  defp list_remote_actor_ids(user_id) do
    from(f in Follow,
      where: f.follower_id == ^user_id and not is_nil(f.remote_actor_id),
      select: f.remote_actor_id
    )
    |> Repo.all()
  end

  defp federated_timeline_query(remote_actor_ids, limit, preloads) do
    from(m in Message,
      where: m.federated == true and m.remote_actor_id in ^remote_actor_ids,
      where: is_nil(m.deleted_at),
      where: m.is_draft != true,
      where: m.visibility in ["public", "unlisted", "followers"],
      order_by: [desc: m.id],
      limit: ^limit,
      preload: ^preloads
    )
  end

  defp local_combined_feed_query(following_ids, blocked_ids) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        c.type == "timeline" and
          m.post_type == "post" and
          is_nil(m.deleted_at) and
          m.is_draft != true and
          m.sender_id in ^following_ids and
          m.sender_id not in ^blocked_ids and
          m.visibility in ["public", "unlisted", "followers"] and
          is_nil(m.reply_to_id),
      select: m
    )
  end

  defp maybe_federated_combined_query([]), do: nil

  defp maybe_federated_combined_query(remote_actor_ids) do
    from(m in Message,
      where:
        m.federated == true and
          m.remote_actor_id in ^remote_actor_ids and
          is_nil(m.deleted_at) and
          m.is_draft != true and
          m.visibility in ["public", "unlisted", "followers"] and
          is_nil(m.reply_to_id),
      select: m
    )
  end

  defp maybe_followed_hashtag_combined_query(user_id, blocked_ids) when is_integer(user_id) do
    followed_hashtag_ids =
      from(hf in HashtagFollow,
        where: hf.user_id == ^user_id,
        select: hf.hashtag_id
      )
      |> Repo.all()

    case followed_hashtag_ids do
      [] ->
        nil

      _ ->
        followed_hashtag_combined_query(followed_hashtag_ids, blocked_ids)
    end
  end

  defp maybe_followed_hashtag_combined_query(_user_id, _blocked_ids), do: nil

  defp followed_hashtag_combined_query(hashtag_ids, blocked_ids) do
    from(m in Message,
      join: ph in PostHashtag,
      on: ph.message_id == m.id,
      left_join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        ph.hashtag_id in ^hashtag_ids and
          is_nil(m.deleted_at) and
          m.is_draft != true and
          m.visibility in ["public", "unlisted"] and
          is_nil(m.reply_to_id) and
          (is_nil(c.id) or c.type == "timeline"),
      where: is_nil(m.sender_id) or m.sender_id not in ^blocked_ids,
      select: m
    )
  end

  defp combined_feed_query(local_query, optional_queries, limit, preloads)
       when is_list(optional_queries) do
    combined_query =
      optional_queries
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(local_query, fn query, acc -> union_all(acc, ^query) end)

    from(m in subquery(combined_query),
      distinct: [desc: m.id],
      order_by: [desc: m.id],
      limit: ^limit,
      preload: ^preloads
    )
  end

  @doc """
  Gets local timeline - top-level posts from local users only.
  Local posts are identified by having a sender_id (local user) and no remote_actor_id.
  """
  def get_local_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    only_media = Keyword.get(opts, :only_media, false)
    preloads = MessagingMessages.timeline_feed_preloads()

    all_blocked_ids = blocked_user_ids(user_id)

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        # Local posts: have sender_id (local user), no remote_actor_id
        # Include all types: posts, replies, community posts
        where:
          c.type == "timeline" and
            not is_nil(m.sender_id) and
            is_nil(m.remote_actor_id) and
            m.visibility == "public" and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
    query = maybe_apply_viewer_timeline_policy(query, user_id)
    query = maybe_apply_timeline_search(query, search_query)
    query = maybe_filter_timeline_media(query, only_media)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets all public federated posts (discover feed).
  """
  def get_public_federated_posts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
    search_query = Keyword.get(opts, :search_query)
    preloads = MessagingMessages.timeline_feed_preloads()

    if Elektrine.Strings.present?(search_query) do
      get_public_federated_posts_query(limit, pagination, user_id, search_query, preloads)
    else
      get_public_federated_posts_fast(limit, pagination, preloads, user_id)
    end
  end

  defp get_public_federated_posts_fast(limit, pagination, preloads, user_id) do
    candidate_limit = max(limit * 10, 100)

    # Phase 1: fetch only the fields needed to evaluate exclusion policies, so
    # rejected candidates never pay the cost of full preload hydration.
    candidate_query =
      from(m in Message,
        left_join: ra in assoc(m, :remote_actor),
        where: m.federated == true and m.visibility == "public",
        where:
          m.is_draft != true and is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^candidate_limit,
        select: %{id: m.id, sender_id: m.sender_id, actor_uri: ra.uri, actor_domain: ra.domain}
      )

    excluded_domains = compile_domain_policy(public_timeline_excluded_instance_domains())
    viewer_policy = public_timeline_viewer_policy(user_id)

    selected_ids =
      candidate_query
      |> apply_id_pagination(pagination)
      |> apply_id_order(pagination.order)
      |> Repo.all()
      |> Enum.reject(&public_timeline_post_excluded?(&1, excluded_domains, viewer_policy))
      |> Enum.take(limit)
      |> Enum.map(& &1.id)

    # Phase 2: hydrate full posts with preloads only for the kept candidates.
    if selected_ids == [] do
      []
    else
      from(m in Message, where: m.id in ^selected_ids, preload: ^preloads)
      |> apply_id_order(pagination.order)
      |> Repo.all()
    end
  end

  defp get_public_federated_posts_query(limit, pagination, user_id, search_query, preloads) do
    query =
      from(m in Message,
        where: m.federated == true and m.visibility == "public",
        where:
          m.is_draft != true and is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads
      )

    query =
      query
      |> maybe_apply_viewer_timeline_policy(user_id)
      |> maybe_exclude_public_timeline_removed_instances()
      |> maybe_apply_timeline_search(search_query)
      |> apply_id_pagination(pagination)
      |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  defp public_timeline_excluded_instance_domains do
    Repo.all(
      from i in Instance,
        where: i.blocked == true or i.silenced == true or i.federated_timeline_removal == true,
        select: i.domain
    )
    |> Enum.filter(&is_binary/1)
  end

  defp public_timeline_viewer_policy(nil) do
    %{
      muted_sender_ids: MapSet.new(),
      blocked_actor_uris: MapSet.new(),
      blocked_domains: compile_domain_policy([])
    }
  end

  defp public_timeline_viewer_policy(user_id) do
    muted_sender_ids =
      Repo.all(
        from m in UserMute,
          where: m.muter_id == ^user_id,
          select: m.muted_id
      )
      |> MapSet.new()

    blocks =
      Repo.all(
        from b in UserBlock,
          where: b.user_id == ^user_id,
          select: {b.block_type, b.blocked_uri}
      )

    %{
      muted_sender_ids: muted_sender_ids,
      blocked_actor_uris:
        blocks
        |> Enum.filter(fn {type, uri} -> type == "user" and is_binary(uri) end)
        |> Enum.map(fn {_type, uri} -> uri end)
        |> MapSet.new(),
      blocked_domains:
        blocks
        |> Enum.filter(fn {type, domain} -> type == "domain" and is_binary(domain) end)
        |> Enum.map(fn {_type, domain} -> domain end)
        |> compile_domain_policy()
    }
  end

  defp public_timeline_post_excluded?(candidate, excluded_domains, viewer_policy) do
    domain_excluded?(excluded_domains, candidate.actor_domain) or
      public_timeline_viewer_policy_excluded?(candidate, viewer_policy)
  end

  defp public_timeline_viewer_policy_excluded?(candidate, policy) do
    MapSet.member?(policy.muted_sender_ids, candidate.sender_id) or
      (is_binary(candidate.actor_uri) &&
         MapSet.member?(policy.blocked_actor_uris, candidate.actor_uri)) or
      domain_excluded?(policy.blocked_domains, candidate.actor_domain)
  end

  defp compile_domain_policy(domains) do
    {wildcards, exacts} =
      domains
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.split_with(&String.starts_with?(&1, "*."))

    %{
      exact: MapSet.new(exacts),
      wildcard_suffixes: Enum.map(wildcards, &("." <> String.trim_leading(&1, "*.")))
    }
  end

  defp domain_excluded?(%{exact: exact, wildcard_suffixes: suffixes}, domain)
       when is_binary(domain) do
    domain = String.downcase(domain)

    MapSet.member?(exact, domain) or Enum.any?(suffixes, &String.ends_with?(domain, &1))
  end

  defp domain_excluded?(_policy, _domain), do: false

  @doc """
  Gets direct replies for a list of posts (for threaded display on timeline).
  Returns a map of post_id => list of replies.
  """
  def get_direct_replies_for_posts(post_ids, opts \\ []) when is_list(post_ids) do
    if Enum.empty?(post_ids) do
      %{}
    else
      user_id = Keyword.get(opts, :user_id)
      # Show first 3 replies by default
      limit_per_post = Keyword.get(opts, :limit_per_post, 3)
      preloads = MessagingMessages.timeline_reply_preview_preloads()

      all_blocked_ids = blocked_user_ids(user_id)

      base_query =
        from m in Message,
          where:
            m.reply_to_id in ^post_ids and
              m.is_draft != true and
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status))

      base_query =
        if user_id do
          from(m in base_query, where: m.visibility in ["public", "unlisted", "followers"])
        else
          from(m in base_query, where: m.visibility in ["public", "unlisted"])
        end

      base_query = maybe_exclude_blocked_senders_or_nil(base_query, all_blocked_ids)
      base_query = maybe_apply_viewer_timeline_policy(base_query, user_id)

      # Keep only the first N replies per parent in SQL instead of loading all replies.
      ranked_ids_query =
        from m in base_query,
          windows: [
            per_parent: [partition_by: m.reply_to_id, order_by: [asc: m.inserted_at, asc: m.id]]
          ],
          select: %{
            id: m.id,
            reply_to_id: m.reply_to_id,
            row_num: over(row_number(), :per_parent)
          }

      replies_query =
        from m in Message,
          join: ranked in subquery(ranked_ids_query),
          on: ranked.id == m.id,
          where: ranked.row_num <= ^limit_per_post,
          order_by: [asc: ranked.reply_to_id, asc: m.inserted_at, asc: m.id],
          preload: ^preloads

      replies = Repo.all(replies_query)

      replies
      |> Enum.group_by(& &1.reply_to_id)
      |> Enum.into(%{}, fn {post_id, post_replies} -> {post_id, post_replies} end)
    end
  end

  ## List Management
  # Delegated to Elektrine.Social.Lists submodule
  defdelegate create_list(attrs \\ %{}), to: Elektrine.Social.Lists
  defdelegate update_list(list, attrs), to: Elektrine.Social.Lists
  defdelegate delete_list(list), to: Elektrine.Social.Lists
  defdelegate get_list(id), to: Elektrine.Social.Lists
  defdelegate get_user_list(user_id, list_id), to: Elektrine.Social.Lists
  defdelegate list_user_lists(user_id), to: Elektrine.Social.Lists
  defdelegate list_public_lists(opts \\ []), to: Elektrine.Social.Lists
  defdelegate search_public_lists(query, opts \\ []), to: Elektrine.Social.Lists
  defdelegate get_public_list(list_id), to: Elektrine.Social.Lists
  defdelegate list_user_lists_for_account(owner_user_id, account), to: Elektrine.Social.Lists
  defdelegate add_to_list(list_id, attrs), to: Elektrine.Social.Lists
  defdelegate add_accounts_to_list(owner_user_id, list_id, attrs), to: Elektrine.Social.Lists
  defdelegate remove_from_list(list_member_id), to: Elektrine.Social.Lists
  defdelegate remove_accounts_from_list(owner_user_id, list_id, attrs), to: Elektrine.Social.Lists
  defdelegate get_list_timeline(list_id, opts \\ []), to: Elektrine.Social.Lists

  # NOTE: Saved Items (Bookmarks) functions are now in Elektrine.Social.Bookmarks
  # and delegated at the top of this module.
end
