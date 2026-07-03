defmodule Elektrine.Social do
  @moduledoc """
  The Social context - handles timeline, following, and social features.
  Builds on top of the existing messaging system.
  """

  import Ecto.Query, warn: false
  import Elektrine.Social.FeedQuery

  alias Elektrine.Accounts
  alias Elektrine.Accounts.{BlockedUsersCache, User}
  alias Elektrine.ActivityPub.Mentions
  alias Elektrine.ActivityPub.Outbox
  alias Elektrine.Async
  alias Elektrine.Friends
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Notifications
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Security.ContentValidator

  alias Elektrine.Social.{
    Conversation,
    ConversationMember,
    Message,
    MessagePolicy,
    TimelineRelationships
  }

  alias Elektrine.Social.{FetchLinkPreviewWorker, HashtagExtractor, LinkPreviewFetcher}
  alias Elektrine.Social.Messages, as: MessagingMessages

  @profile_pin_limit 3
  @profile_pin_visibilities ["public", "unlisted"]

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

  ## Status Reactions - Delegated to Elektrine.Social.StatusReactions
  defdelegate status_liked_by_accounts(message_id, limit \\ 80),
    to: Elektrine.Social.StatusReactions

  defdelegate status_boosted_by_accounts(message_id, limit \\ 80),
    to: Elektrine.Social.StatusReactions

  defdelegate list_status_quotes(message_id, viewer_id, opts \\ []),
    to: Elektrine.Social.StatusReactions

  defdelegate list_status_reactions(message_id, opts \\ []),
    to: Elektrine.Social.StatusReactions

  defdelegate add_status_reaction(user_id, message_id, emoji),
    to: Elektrine.Social.StatusReactions

  defdelegate remove_status_reaction(user_id, message_id, emoji),
    to: Elektrine.Social.StatusReactions

  ## Hashtag System
  defdelegate get_posts_for_hashtag(hashtag_name, opts \\ []), to: HashtagExtractor
  defdelegate get_trending_hashtags(opts \\ []), to: HashtagExtractor
  defdelegate search_hashtags(query, limit \\ 10), to: HashtagExtractor

  # Hashtag CRUD - Delegated to Elektrine.Social.Hashtags
  defdelegate get_or_create_hashtag(name), to: Elektrine.Social.Hashtags
  defdelegate increment_hashtag_usage(hashtag_id), to: Elektrine.Social.Hashtags
  defdelegate decrement_hashtag_usage(hashtag_id), to: Elektrine.Social.Hashtags
  defdelegate get_hashtag_by_normalized_name(normalized_name), to: Elektrine.Social.Hashtags
  defdelegate count_hashtag_posts(hashtag_id, opts \\ []), to: Elektrine.Social.Hashtags
  defdelegate list_hashtag_posts(hashtag_id, opts \\ []), to: Elektrine.Social.Hashtags

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

  ## Media Attachment Metadata - Delegated to Elektrine.Social.MediaAttachments
  defdelegate merge_post_media_metadata(
                base_metadata \\ %{},
                alt_texts \\ %{},
                community_actor_uri \\ nil
              ),
              to: Elektrine.Social.MediaAttachments

  defdelegate update_media_attachment_metadata(user_id, media_id, attrs),
    to: Elektrine.Social.MediaAttachments

  defp build_media_metadata(base_metadata, alt_texts, community_actor_uri) do
    Elektrine.Social.MediaAttachments.merge_post_media_metadata(
      base_metadata,
      alt_texts,
      community_actor_uri
    )
  end

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

  ## Suggested Follows - Delegated to Elektrine.Social.SuggestedFollows
  defdelegate get_suggested_follows(user_id, opts \\ []), to: Elektrine.Social.SuggestedFollows

  defdelegate dismiss_suggested_follow(user_id, suggested_user_id),
    to: Elektrine.Social.SuggestedFollows

  # Add missing helper function for timeline LiveView
  # Uses abbreviated format (5m, 2h, 3d) - delegates to shared TextHelpers
  def time_ago_in_words(datetime), do: Elektrine.TextHelpers.time_ago_short(datetime)

  ## Discussion Posts - Delegated to Elektrine.Social.Discussions
  defdelegate get_discussion_posts(conversation_id, opts \\ []), to: Elektrine.Social.Discussions

  defdelegate count_discussion_posts(conversation_id, opts \\ []),
    to: Elektrine.Social.Discussions

  defdelegate get_related_discussion_posts(conversation_id, current_post_id, opts \\ []),
    to: Elektrine.Social.Discussions

  defdelegate get_trending_discussions(opts \\ []), to: Elektrine.Social.Discussions

  defdelegate get_recent_community_activity(user_id, opts \\ []),
    to: Elektrine.Social.Discussions

  defdelegate get_user_community_posts(user_id, opts \\ []), to: Elektrine.Social.Discussions

  defdelegate get_popular_communities_this_week(opts \\ []), to: Elektrine.Social.Discussions

  defdelegate get_suggested_discussion_topics(user_id, opts \\ []),
    to: Elektrine.Social.Discussions

  # NOTE: Voting functions are now in Elektrine.Social.Votes
  # and delegated at the top of this module.

  ## Cross-Context Content Promotion - Delegated to Elektrine.Social.CrossPosting
  defdelegate promote_message_to_timeline(message_id, user_id, opts \\ []),
    to: Elektrine.Social.CrossPosting

  defdelegate cross_post_to_discussion(
                source_message_id,
                user_id,
                community_id,
                title,
                comment \\ ""
              ),
              to: Elektrine.Social.CrossPosting

  defdelegate cross_post_to_chat(source_message_id, user_id, conversation_id, comment \\ ""),
    to: Elektrine.Social.CrossPosting

  defdelegate promote_timeline_to_discussion(message_id, user_id, community_id, opts \\ []),
    to: Elektrine.Social.CrossPosting

  defdelegate discuss_privately(message_id, initiator_user_id, target_user_id, opts \\ []),
    to: Elektrine.Social.CrossPosting

  defdelegate share_to_timeline(source_message_id, user_id, opts \\ []),
    to: Elektrine.Social.CrossPosting

  defdelegate link_discussion_to_timeline(discussion_id, timeline_post_id, user_id),
    to: Elektrine.Social.CrossPosting

  defdelegate get_unified_replies(post_id), to: Elektrine.Social.CrossPosting

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

  ## Poll System - Delegated to Elektrine.Social.Polls
  defdelegate create_poll(message_id, question, options, opts \\ []), to: Elektrine.Social.Polls
  defdelegate vote_on_poll(poll_id, option_id, user_id), to: Elektrine.Social.Polls
  defdelegate get_poll(poll_id), to: Elektrine.Social.Polls
  defdelegate set_poll_votes(poll_id, option_ids, user_id), to: Elektrine.Social.Polls
  defdelegate clear_poll_votes(poll_id, user_id), to: Elektrine.Social.Polls
  defdelegate get_poll_results(poll_id), to: Elektrine.Social.Polls
  defdelegate get_user_poll_votes(poll_id, user_id), to: Elektrine.Social.Polls

  # NOTE: Post View Tracking functions are now in Elektrine.Social.Views
  # These are delegated at the top of this module.

  ## Federated Feeds - Delegated to Elektrine.Social.FederatedFeeds
  defdelegate get_federated_timeline(user_id, opts \\ []), to: Elektrine.Social.FederatedFeeds
  defdelegate get_combined_feed(user_id, opts \\ []), to: Elektrine.Social.FederatedFeeds
  defdelegate get_local_timeline(opts \\ []), to: Elektrine.Social.FederatedFeeds
  defdelegate get_public_federated_posts(opts \\ []), to: Elektrine.Social.FederatedFeeds

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
