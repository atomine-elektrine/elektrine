defmodule Elektrine.Social.FederatedFeeds do
  @moduledoc """
  Federated, combined, and local timeline feeds.
  """

  import Ecto.Query, warn: false
  import Elektrine.Social.FeedQuery

  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.UserBlock
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Conversation
  alias Elektrine.Social.FeedPolicy
  alias Elektrine.Social.HashtagFollow
  alias Elektrine.Social.HomeFeedCache
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessagePolicy
  alias Elektrine.Social.Messages, as: MessagingMessages
  alias Elektrine.Social.PostHashtag

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
        # The query admits "followers" visibility; enforce the actual (accepted)
        # follow relationship per post so a pending follower can't see a remote
        # actor's followers-only content.
        |> Enum.filter(&MessagePolicy.visible?(user_id, &1))
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
      where:
        f.follower_id == ^user_id and not is_nil(f.remote_actor_id) and
          f.pending == false,
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
end
