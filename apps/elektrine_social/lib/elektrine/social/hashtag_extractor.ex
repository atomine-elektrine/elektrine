defmodule Elektrine.Social.HashtagExtractor do
  @moduledoc """
  Extracts hashtags from text content and manages hashtag associations.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{BlockedUsersCache, UserMute}
  alias Elektrine.ActivityPub.{Instance, UserBlock}
  alias Elektrine.Repo
  alias Elektrine.Social.{Hashtag, PostHashtag}
  alias Elektrine.Social.Message

  @doc """
  Extracts hashtags from text content.
  """
  def extract_hashtags(content) do
    # Regex to match hashtags: # followed by word characters
    hashtag_regex = ~r/#(\w+)/

    Regex.scan(hashtag_regex, content)
    # Get the captured group (without #)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.filter(&valid_hashtag?/1)
  end

  @doc """
  Creates or updates hashtags and associates them with a message.
  """
  def process_hashtags_for_message(message_id, hashtags) when is_list(hashtags) do
    Enum.each(hashtags, fn hashtag_name ->
      hashtag = get_or_create_hashtag(hashtag_name)
      create_post_hashtag_association(message_id, hashtag.id)
      increment_hashtag_usage(hashtag.id)
    end)
  end

  @doc """
  Gets posts for a specific hashtag (includes local and federated posts).
  """
  def get_posts_for_hashtag(hashtag_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    user_id = Keyword.get(opts, :user_id)
    preloads = Elektrine.Social.Messages.timeline_post_preloads()

    blocked_user_ids =
      if user_id, do: BlockedUsersCache.get_all_blocked_user_ids(user_id), else: []

    normalized_name = String.downcase(hashtag_name)
    candidate_limit = max(limit * 10, 100)

    query =
      from m in Message,
        join: ph in PostHashtag,
        on: ph.message_id == m.id,
        join: h in Hashtag,
        on: h.id == ph.hashtag_id,
        left_join: remote_actor in assoc(m, :remote_actor),
        where:
          h.normalized_name == ^normalized_name and
            m.visibility in ["public", "unlisted"] and
            m.is_draft != true and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            (m.sender_id not in ^blocked_user_ids or is_nil(m.sender_id)) and
            (not is_nil(m.sender_id) or not is_nil(m.remote_actor_id)),
        order_by: [desc: m.id],
        limit: ^candidate_limit,
        select: %{
          id: m.id,
          sender_id: m.sender_id,
          actor_uri: remote_actor.uri,
          actor_domain: remote_actor.domain
        }

    query =
      if before_id, do: from(m in query, where: m.id < ^before_id), else: query

    excluded_domains = compile_domain_policy(public_timeline_excluded_instance_domains())
    viewer_policy = viewer_policy(user_id)

    post_ids =
      query
      |> Repo.all()
      |> Enum.reject(&candidate_excluded?(&1, excluded_domains, viewer_policy))
      |> Enum.take(limit)
      |> Enum.map(& &1.id)

    if post_ids == [] do
      []
    else
      # Reuse standard timeline preloads so hashtag cards match timeline/detail rendering.
      from(m in Message, where: m.id in ^post_ids, order_by: [desc: m.id], preload: ^preloads)
      |> Repo.all()
    end
  end

  @doc """
  Gets trending hashtags based on recent usage.
  """
  def get_trending_hashtags(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days_back = Keyword.get(opts, :days_back, 7)

    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back, :day)

    from(h in Hashtag,
      where: h.last_used_at > ^cutoff_date,
      order_by: [desc: h.use_count, desc: h.last_used_at],
      limit: ^limit,
      select: %{
        name: h.name,
        normalized_name: h.normalized_name,
        use_count: h.use_count,
        last_used_at: h.last_used_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Searches hashtags by name.
  """
  def search_hashtags(query, limit \\ 10) do
    search_term = "%#{String.downcase(query)}%"

    from(h in Hashtag,
      where: ilike(h.normalized_name, ^search_term),
      order_by: [desc: h.use_count],
      limit: ^limit,
      select: %{
        name: h.name,
        normalized_name: h.normalized_name,
        use_count: h.use_count
      }
    )
    |> Repo.all()
  end

  # Private functions

  defp public_timeline_excluded_instance_domains do
    Repo.all(
      from i in Instance,
        where: i.blocked == true or i.silenced == true or i.federated_timeline_removal == true,
        select: i.domain
    )
    |> Enum.filter(&is_binary/1)
  end

  defp viewer_policy(nil) do
    %{
      muted_sender_ids: MapSet.new(),
      blocked_actor_uris: MapSet.new(),
      blocked_domains: compile_domain_policy([])
    }
  end

  defp viewer_policy(user_id) do
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

  defp candidate_excluded?(candidate, excluded_domains, viewer_policy) do
    domain_excluded?(excluded_domains, candidate.actor_domain) or
      MapSet.member?(viewer_policy.muted_sender_ids, candidate.sender_id) or
      (is_binary(candidate.actor_uri) &&
         MapSet.member?(viewer_policy.blocked_actor_uris, candidate.actor_uri)) or
      domain_excluded?(viewer_policy.blocked_domains, candidate.actor_domain)
  end

  defp compile_domain_policy(domains) do
    {wildcards, exacts} =
      domains
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
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

  defp valid_hashtag?(hashtag) do
    # Basic validation: length between 1-50 chars, alphanumeric + underscore
    String.length(hashtag) >= 1 and
      String.length(hashtag) <= 50 and
      Regex.match?(~r/^[a-zA-Z0-9_]+$/, hashtag)
  end

  defp get_or_create_hashtag(name) do
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

  defp first_hashtag_by_normalized_name(normalized_name) do
    from(h in Hashtag,
      where: h.normalized_name == ^normalized_name,
      order_by: [asc: h.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp create_post_hashtag_association(message_id, hashtag_id) do
    %PostHashtag{}
    |> PostHashtag.changeset(%{
      message_id: message_id,
      hashtag_id: hashtag_id
    })
    |> Repo.insert()
  end

  defp increment_hashtag_usage(hashtag_id) do
    from(h in Hashtag, where: h.id == ^hashtag_id)
    |> Repo.update_all(
      inc: [use_count: 1],
      set: [last_used_at: Elektrine.Time.utc_now()]
    )
  end
end
