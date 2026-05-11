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

    query =
      from m in Message,
        join: ph in PostHashtag,
        on: ph.message_id == m.id,
        join: h in Hashtag,
        on: h.id == ph.hashtag_id,
        where:
          h.normalized_name == ^normalized_name and
            m.visibility in ["public", "unlisted"] and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            (m.sender_id not in ^blocked_user_ids or is_nil(m.sender_id)) and
            (not is_nil(m.sender_id) or not is_nil(m.remote_actor_id)),
        order_by: [desc: m.id],
        limit: ^limit

    # Reuse standard timeline preloads so hashtag cards match timeline/detail rendering.
    query =
      from m in query,
        preload: ^preloads

    query =
      if before_id do
        from m in query, where: m.id < ^before_id
      else
        query
      end

    query = apply_viewer_policy(query, user_id)

    Repo.all(query)
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

  defp apply_viewer_policy(query, user_id) do
    query
    |> exclude_muted_senders(user_id)
    |> exclude_blocked_remote_actors(user_id)
    |> exclude_blocked_domains(user_id)
    |> exclude_blocked_instances()
    |> exclude_public_timeline_removed_instances()
  end

  defp exclude_muted_senders(query, nil), do: query

  defp exclude_muted_senders(query, user_id) do
    from(m in query,
      left_join: mute in UserMute,
      on: mute.muter_id == ^user_id and mute.muted_id == m.sender_id,
      where: is_nil(mute.id)
    )
  end

  defp exclude_blocked_remote_actors(query, nil), do: query

  defp exclude_blocked_remote_actors(query, user_id) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_remote_actor in UserBlock,
      on:
        blocked_remote_actor.user_id == ^user_id and blocked_remote_actor.block_type == "user" and
          blocked_remote_actor.blocked_uri == remote_actor.uri,
      where: is_nil(remote_actor.id) or is_nil(blocked_remote_actor.id)
    )
  end

  defp exclude_blocked_domains(query, nil), do: query

  defp exclude_blocked_domains(query, user_id) do
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

  defp exclude_blocked_instances(query) do
    if Repo.exists?(from(i in Instance, where: i.blocked == true)) do
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

  defp exclude_public_timeline_removed_instances(query) do
    if Repo.exists?(
         from(i in Instance, where: i.silenced == true or i.federated_timeline_removal == true)
       ) do
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
