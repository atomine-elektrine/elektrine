defmodule Elektrine.Social do
  @moduledoc """
  The Social context - handles timeline, following, and social features.
  Builds on top of the existing messaging system.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts
  alias Elektrine.Accounts.{BlockedUsersCache, User}
  alias Elektrine.ActivityPub.Outbox
  alias Elektrine.Async
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{Conversation, Message}
  alias Elektrine.Messaging.ConversationMember
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Notifications
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Security.ContentValidator
  alias Elektrine.Social.{FetchLinkPreviewWorker, Hashtag, HashtagExtractor, LinkPreviewFetcher}
  @discussion_post_types ["discussion", "link", "poll"]
  @public_audience_uris ["Public", "as:Public", "https://www.w3.org/ns/activitystreams#Public"]

  ## Following System

  # Use existing Profiles follow functions instead of duplicating
  defdelegate follow_user(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate unfollow_user(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate following?(follower_id, followed_id), to: Elektrine.Profiles
  defdelegate get_follower_count(user_id), to: Elektrine.Profiles
  defdelegate get_following_count(user_id), to: Elektrine.Profiles

  ## Bookmarks (Saved Items) - Delegated to Elektrine.Social.Bookmarks
  defdelegate save_post(user_id, message_id), to: Elektrine.Social.Bookmarks
  defdelegate save_rss_item(user_id, rss_item_id), to: Elektrine.Social.Bookmarks
  defdelegate unsave_post(user_id, message_id), to: Elektrine.Social.Bookmarks
  defdelegate unsave_rss_item(user_id, rss_item_id), to: Elektrine.Social.Bookmarks
  defdelegate post_saved?(user_id, message_id), to: Elektrine.Social.Bookmarks
  defdelegate rss_item_saved?(user_id, rss_item_id), to: Elektrine.Social.Bookmarks
  defdelegate list_user_saved_posts(user_id, message_ids), to: Elektrine.Social.Bookmarks
  defdelegate list_user_saved_rss_items(user_id, rss_item_ids), to: Elektrine.Social.Bookmarks
  defdelegate get_saved_posts(user_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate get_saved_rss_items(user_id, opts \\ []), to: Elektrine.Social.Bookmarks
  defdelegate count_saved_posts(user_id), to: Elektrine.Social.Bookmarks

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

  ## Boosts - Delegated to Elektrine.Social.Boosts
  defdelegate boost_post(user_id, message_id), to: Elektrine.Social.Boosts
  defdelegate unboost_post(user_id, message_id), to: Elektrine.Social.Boosts

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

  ## Hashtag System
  defdelegate get_posts_for_hashtag(hashtag_name, opts \\ []), to: HashtagExtractor
  defdelegate get_trending_hashtags(opts \\ []), to: HashtagExtractor
  defdelegate search_hashtags(query, limit \\ 10), to: HashtagExtractor

  @doc """
  Gets or creates a hashtag by name.
  """
  def get_or_create_hashtag(name) do
    normalized_name = String.downcase(name)

    case Repo.get_by(Hashtag, normalized_name: normalized_name) do
      nil ->
        # Create new hashtag
        case %Hashtag{}
             |> Hashtag.changeset(%{
               name: name,
               normalized_name: normalized_name,
               use_count: 0,
               last_used_at: DateTime.utc_now()
             })
             |> Repo.insert() do
          {:ok, hashtag} ->
            hashtag

          {:error, _} ->
            # Race condition - try to get existing
            Repo.get_by(Hashtag, normalized_name: normalized_name)
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
      set: [last_used_at: DateTime.utc_now()]
    )
  end

  @doc """
  Gets a hashtag by its normalized name.
  """
  def get_hashtag_by_normalized_name(normalized_name) do
    Repo.get_by(Hashtag, normalized_name: String.downcase(normalized_name))
  end

  @doc """
  Counts posts with a specific hashtag (for ActivityPub collections).
  """
  def count_hashtag_posts(hashtag_id, opts \\ []) do
    visibility = Keyword.get(opts, :visibility)

    query =
      from(m in Message,
        join: ph in "post_hashtags",
        on: ph.message_id == m.id,
        where: ph.hashtag_id == ^hashtag_id and is_nil(m.deleted_at)
      )

    query =
      if visibility do
        from(m in query, where: m.visibility == ^visibility)
      else
        query
      end

    Repo.aggregate(query, :count, :id)
  end

  @doc """
  Lists posts with a specific hashtag (for ActivityPub collections).
  """
  def list_hashtag_posts(hashtag_id, opts \\ []) do
    visibility = Keyword.get(opts, :visibility)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    preload = Keyword.get(opts, :preload, [])

    query =
      from(m in Message,
        join: ph in "post_hashtags",
        on: ph.message_id == m.id,
        where: ph.hashtag_id == ^hashtag_id and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query =
      if visibility do
        from(m in query, where: m.visibility == ^visibility)
      else
        query
      end

    Repo.all(query)
    |> Repo.preload(preload)
  end

  ## Timeline/Posts

  @doc """
  Creates a timeline post (uses existing message system).
  """
  def create_timeline_post(user_id, content, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, "followers")
    media_urls = Keyword.get(opts, :media_urls, [])
    alt_texts = Keyword.get(opts, :alt_texts, %{})
    title = Keyword.get(opts, :title)
    post_type = Keyword.get(opts, :post_type, "post")
    category = Keyword.get(opts, :category)
    community_actor_uri = Keyword.get(opts, :community_actor_uri)

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
          alt_texts: alt_texts,
          community_actor_uri: community_actor_uri,
          category: category
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
  Gets public timeline (discovery feed).
  """
  def get_public_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
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
    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
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
            is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            m.inserted_at > ^seven_days_ago,
        order_by: [desc: m.like_count, desc: m.reply_count, desc: m.inserted_at],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
    query = maybe_before_id(query, pagination.before_id)

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
    preloads = MessagingMessages.timeline_feed_preloads()
    all_blocked_ids = blocked_user_ids(user_id)

    query =
      from m in Message,
        left_join: parent in Message,
        on: parent.id == m.reply_to_id,
        left_join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.visibility == "public" and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            ((not is_nil(m.reply_to_id) and parent.federated == true) or
               fragment("(?->>'inReplyTo' IS NOT NULL)", m.media_metadata)) and
            (c.type == "timeline" or (is_nil(m.conversation_id) and m.federated == true)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders_or_nil(query, all_blocked_ids)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets timeline posts from local friends.
  """
  def get_friends_timeline(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
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
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status)) and
              is_nil(m.reply_to_id) and
              fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata),
          order_by: [desc: m.id],
          limit: ^limit,
          preload: ^preloads

      query = maybe_exclude_blocked_senders(query, all_blocked_ids)
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
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            is_nil(m.reply_to_id) and
            fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
            u.trust_level >= 2,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets gallery feed for a user (posts from people they follow with post_type: "gallery").
  """
  def get_gallery_feed(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
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
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            m.sender_id not in ^all_blocked_ids,
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [sender: [:profile]]

    # Filter based on following_only option
    query =
      if following_only do
        from m in query, where: m.sender_id in ^following_ids
      else
        from m in query, where: m.sender_id in ^following_ids or m.visibility == "public"
      end

    query =
      if before_id do
        from m in query, where: m.id < ^before_id
      else
        query
      end

    Repo.all(query)
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
          m.visibility in ^visibility_levels and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 3,
      preload: ^preloads
    )
    |> Repo.all()
  end

  def get_user_timeline_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    pagination = pagination_opts(opts)
    viewer_id = Keyword.get(opts, :viewer_id)
    preloads = MessagingMessages.timeline_feed_preloads()
    visibility_levels = visibility_levels_for_viewer(user_id, viewer_id)

    query =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.sender_id == ^user_id and
            m.post_type == "post" and
            m.visibility in ^visibility_levels and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads
      )

    query
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

  defp build_media_metadata(alt_texts, community_actor_uri) do
    %{}
    |> maybe_put_alt_texts(alt_texts)
    |> maybe_put_community_actor_uri(community_actor_uri)
  end

  defp maybe_put_alt_texts(metadata, nil), do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts) when map_size(alt_texts) == 0, do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts), do: Map.put(metadata, "alt_texts", alt_texts)

  defp maybe_put_community_actor_uri(metadata, nil), do: metadata
  defp maybe_put_community_actor_uri(metadata, ""), do: metadata

  defp maybe_put_community_actor_uri(metadata, community_actor_uri)
       when is_binary(community_actor_uri) do
    normalized = String.trim(community_actor_uri)

    if normalized == "" || normalized in @public_audience_uris do
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
         alt_texts: alt_texts,
         community_actor_uri: community_actor_uri,
         category: category
       }) do
    final_title = validated_title || auto_title
    is_auto_title = is_nil(validated_title) and not is_nil(auto_title)
    media_metadata = build_media_metadata(alt_texts, community_actor_uri)

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
        broadcast_timeline_post(message)
        maybe_federate_timeline_post(message)
        reloaded_message = Repo.preload(message, [:link_preview, :hashtags, sender: :profile])
        {:ok, %{reloaded_message | like_count: 0, reply_count: 0, share_count: 0}}

      error ->
        error
    end
  end

  defp blocked_user_ids(nil), do: []
  defp blocked_user_ids(user_id), do: BlockedUsersCache.get_all_blocked_user_ids(user_id)

  defp maybe_before_id(query, nil), do: query
  defp maybe_before_id(query, before_id), do: from(m in query, where: m.id < ^before_id)
  defp maybe_after_id(query, nil), do: query
  defp maybe_after_id(query, after_id), do: from(m in query, where: m.id > ^after_id)

  defp apply_id_pagination(query, %{before_id: before_id} = pagination) do
    lower_bound = pagination_lower_bound(pagination)

    query
    |> maybe_before_id(before_id)
    |> maybe_after_id(lower_bound)
  end

  defp apply_id_order(query, :asc) do
    query
    |> exclude(:order_by)
    |> order_by([m], asc: m.id)
  end

  defp apply_id_order(query, :desc) do
    query
    |> exclude(:order_by)
    |> order_by([m], desc: m.id)
  end

  defp pagination_requested?(%{before_id: nil, since_id: nil, min_id: nil}), do: false
  defp pagination_requested?(_), do: true

  defp pagination_lower_bound(%{since_id: nil, min_id: nil}), do: nil
  defp pagination_lower_bound(%{since_id: since_id, min_id: nil}), do: since_id
  defp pagination_lower_bound(%{since_id: nil, min_id: min_id}), do: min_id
  defp pagination_lower_bound(%{since_id: since_id, min_id: min_id}), do: max(since_id, min_id)

  defp pagination_opts(opts, default_order \\ :desc) do
    before_id = parse_pagination_id(Keyword.get(opts, :before_id) || Keyword.get(opts, :cursor))
    since_id = parse_pagination_id(Keyword.get(opts, :since_id))
    min_id = parse_pagination_id(Keyword.get(opts, :min_id))
    order = normalize_pagination_order(Keyword.get(opts, :order), default_order, min_id)

    %{
      before_id: before_id,
      since_id: since_id,
      min_id: min_id,
      order: order
    }
  end

  defp normalize_pagination_order(nil, _default_order, min_id) when is_integer(min_id), do: :asc
  defp normalize_pagination_order(nil, default_order, _min_id), do: default_order
  defp normalize_pagination_order(:asc, _default_order, _min_id), do: :asc
  defp normalize_pagination_order(:desc, _default_order, _min_id), do: :desc

  defp normalize_pagination_order(order, default_order, _min_id) when is_binary(order) do
    case String.downcase(order) do
      "asc" -> :asc
      "desc" -> :desc
      _ -> default_order
    end
  end

  defp normalize_pagination_order(_order, default_order, _min_id), do: default_order

  defp parse_pagination_id(nil), do: nil
  defp parse_pagination_id(value) when is_integer(value) and value > 0, do: value
  defp parse_pagination_id(value) when is_binary(value), do: parse_integer_id(value)
  defp parse_pagination_id(_), do: nil

  defp parse_integer_id(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp maybe_exclude_blocked_senders(query, []), do: query

  defp maybe_exclude_blocked_senders(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids)
  end

  defp maybe_exclude_blocked_senders_or_nil(query, []), do: query

  defp maybe_exclude_blocked_senders_or_nil(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids or is_nil(m.sender_id))
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
        (m.sender_id in ^following_ids and m.visibility in ["public", "followers"]) or
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
    # Increment the count in the database
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(inc: [reply_count: 1])

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

  @doc """
  Broadcasts a timeline post to followers via PubSub.
  """
  def broadcast_timeline_post(message) do
    # Broadcast to all followers in a single batch query
    follower_ids =
      from(f in Follow,
        where: f.followed_id == ^message.sender_id,
        select: f.follower_id
      )
      |> Repo.all()

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

    suggestions =
      suggested_active_users(user_id, following_ids, limit) ++
        suggested_mutual_users(user_id, following_ids, limit) ++
        suggested_popular_users(user_id, following_ids, limit)

    suggestions
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
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
        "hot" -> [desc: :score, desc: :upvotes, desc: :inserted_at]
        _ -> [desc: :score, desc: :inserted_at]
      end

    base_query =
      from(m in discussion_post_query(conversation_id),
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
  def count_discussion_posts(conversation_id) do
    from(m in discussion_post_query(conversation_id), select: count(m.id))
    |> Repo.one() || 0
  end

  defp discussion_post_query(conversation_id) do
    from(m in Message,
      where:
        m.conversation_id == ^conversation_id and
          (m.post_type in ^@discussion_post_types or is_nil(m.post_type)) and
          is_nil(m.deleted_at) and
          is_nil(m.reply_to_id) and
          (is_nil(m.is_pinned) or m.is_pinned == false) and
          (m.approval_status == "approved" or is_nil(m.approval_status))
    )
  end

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
      where: c.type == "community" and c.is_public == true,
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

  defp suggested_discussion_title(%{title: title}) when is_binary(title) and title != "",
    do: "Discussion: #{title}"

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
    if String.trim(title) == "" do
      {:ok, nil}
    else
      case ContentValidator.validate_title(title) do
        {:ok, validated} -> {:ok, validated}
        error -> error
      end
    end
  end

  # Allow empty content if media is present
  defp validate_content_or_allow_empty(content, media_urls) do
    if (is_nil(content) || String.trim(content) == "") && !Enum.empty?(media_urls) do
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
    # Extract @mentions from content
    mentions =
      Regex.scan(~r/@(\w+)/, content)
      |> Enum.map(fn [_, username] -> username end)
      |> Enum.uniq()

    # Get sender info
    sender = Accounts.get_user!(sender_id)

    Enum.each(mentions, fn username ->
      maybe_notify_mention(username, sender, sender_id, message_id)
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

    # Increment all parents in a single batch update per parent
    Enum.each(parent_ids, fn parent_id ->
      from(m in Message, where: m.id == ^parent_id)
      |> Repo.update_all(inc: [reply_count: 1])
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

    if length(options) < 2 do
      {:error, "Poll must have at least 2 options"}
    else
      Repo.transaction(fn ->
        create_poll_transaction(message_id, question, closes_at, allow_multiple, options)
      end)
    end
  end

  defp create_poll_transaction(message_id, question, closes_at, allow_multiple, options) do
    case insert_poll(message_id, question, closes_at, allow_multiple) do
      {:ok, poll} ->
        poll_options = insert_poll_options(poll.id, options)
        %{poll | options: poll_options}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_poll(message_id, question, closes_at, allow_multiple) do
    poll_attrs = %{
      message_id: message_id,
      question: question,
      closes_at: closes_at,
      allow_multiple: allow_multiple
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

    with :ok <- validate_poll_vote_target(poll, option_id) do
      existing_votes = list_poll_votes_for_user(poll_id, user_id)
      result = apply_poll_vote(poll, poll_id, option_id, user_id, existing_votes)
      finalize_poll_vote_result(result, poll, option_id, user_id)
    end
  end

  defp validate_poll_vote_target(poll, option_id) do
    cond do
      Poll.closed?(poll) -> {:error, :poll_closed}
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

    from(p in Poll, where: p.id == ^poll_id)
    |> Repo.update_all(set: [total_votes: total_votes])

    # Broadcast poll update
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "poll:#{poll_id}",
      {:poll_updated, poll_id}
    )
  end

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
    preloads = MessagingMessages.timeline_feed_preloads()

    remote_actor_ids = list_remote_actor_ids(user_id)
    following_ids = get_following_user_ids(user_id)
    all_blocked_ids = blocked_user_ids(user_id)
    local_query = local_combined_feed_query(following_ids, all_blocked_ids)
    federated_query = maybe_federated_combined_query(remote_actor_ids)
    query = combined_feed_query(local_query, federated_query, limit, preloads)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
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
      where: m.visibility in ["public", "unlisted"],
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
          m.sender_id in ^following_ids and
          m.sender_id not in ^blocked_ids and
          m.visibility in ["public", "followers"] and
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
          m.visibility in ["public", "unlisted"] and
          is_nil(m.reply_to_id),
      select: m
    )
  end

  defp combined_feed_query(local_query, nil, limit, preloads) do
    from(m in local_query,
      order_by: [desc: m.id],
      limit: ^limit,
      preload: ^preloads
    )
  end

  defp combined_feed_query(local_query, federated_query, limit, preloads) do
    from(m in subquery(union_all(local_query, ^federated_query)),
      order_by: [desc: m.id],
      limit: ^limit,
      preload: ^preloads
    )
  end

  @doc """
  Gets local timeline - posts from local users only (includes replies and community posts).
  Local posts are identified by having a sender_id (local user) and no remote_actor_id.
  """
  def get_local_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pagination = pagination_opts(opts)
    user_id = Keyword.get(opts, :user_id)
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
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads

    query = maybe_exclude_blocked_senders(query, all_blocked_ids)
    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)

    Repo.all(query)
  end

  @doc """
  Gets all public federated posts (discover feed).
  """
  def get_public_federated_posts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = pagination_opts(opts)
    preloads = MessagingMessages.timeline_feed_preloads()

    query =
      from(m in Message,
        where: m.federated == true and m.visibility == "public",
        where: is_nil(m.deleted_at) and is_nil(m.reply_to_id),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: ^preloads
      )

    query = query |> apply_id_pagination(pagination) |> apply_id_order(pagination.order)
    Repo.all(query)
  end

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
              is_nil(m.deleted_at) and
              (m.approval_status == "approved" or is_nil(m.approval_status))

      base_query = maybe_exclude_blocked_senders_or_nil(base_query, all_blocked_ids)

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
  defdelegate add_to_list(list_id, attrs), to: Elektrine.Social.Lists
  defdelegate remove_from_list(list_member_id), to: Elektrine.Social.Lists
  defdelegate get_list_timeline(list_id, opts \\ []), to: Elektrine.Social.Lists

  # NOTE: Saved Items (Bookmarks) functions are now in Elektrine.Social.Bookmarks
  # and delegated at the top of this module.
end
