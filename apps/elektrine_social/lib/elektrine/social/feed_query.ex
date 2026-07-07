defmodule Elektrine.Social.FeedQuery do
  @moduledoc """
  Shared Ecto query helpers for timeline, feed, and discussion queries.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.BlockedUsersCache
  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.UserBlock
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.TimelinePagination

  def blocked_user_ids(nil), do: []
  def blocked_user_ids(user_id), do: BlockedUsersCache.get_all_blocked_user_ids(user_id)

  def apply_id_pagination(query, %{before_id: before_id} = pagination) do
    TimelinePagination.apply(query, %{pagination | before_id: before_id})
  end

  def apply_id_order(query, :asc), do: TimelinePagination.order(query, :asc)

  def apply_id_order(query, :desc), do: TimelinePagination.order(query, :desc)

  def pagination_requested?(pagination), do: TimelinePagination.requested?(pagination)

  def pagination_opts(opts, default_order \\ :desc),
    do: TimelinePagination.opts(opts, default_order)

  def maybe_exclude_blocked_senders(query, []), do: query

  def maybe_exclude_blocked_senders(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids)
  end

  def maybe_exclude_blocked_senders_or_nil(query, []), do: query

  def maybe_exclude_blocked_senders_or_nil(query, blocked_ids) do
    from(m in query, where: m.sender_id not in ^blocked_ids or is_nil(m.sender_id))
  end

  def maybe_apply_viewer_timeline_policy(query, nil), do: maybe_exclude_blocked_instances(query)

  def maybe_apply_viewer_timeline_policy(query, user_id) do
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

  def maybe_exclude_blocked_instances(query) do
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

  def maybe_exclude_public_timeline_removed_instances(query) do
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

  def public_timeline_excluded_instance_domains do
    Repo.all(
      from i in Instance,
        where: i.blocked == true or i.silenced == true or i.federated_timeline_removal == true,
        select: i.domain
    )
    |> Enum.filter(&is_binary/1)
  end

  def public_timeline_viewer_policy(nil) do
    %{
      muted_sender_ids: MapSet.new(),
      blocked_actor_uris: MapSet.new(),
      blocked_domains: compile_domain_policy([])
    }
  end

  def public_timeline_viewer_policy(user_id) do
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

  def public_timeline_post_excluded?(candidate, excluded_domains, viewer_policy) do
    domain_excluded?(excluded_domains, candidate.actor_domain) or
      public_timeline_viewer_policy_excluded?(candidate, viewer_policy)
  end

  def compile_domain_policy(domains) do
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

  def domain_excluded?(%{exact: exact, wildcard_suffixes: suffixes}, domain)
      when is_binary(domain) do
    domain = String.downcase(domain)

    MapSet.member?(exact, domain) or Enum.any?(suffixes, &String.ends_with?(domain, &1))
  end

  def domain_excluded?(_policy, _domain), do: false

  defp public_timeline_viewer_policy_excluded?(candidate, policy) do
    MapSet.member?(policy.muted_sender_ids, candidate.sender_id) or
      (is_binary(candidate.actor_uri) &&
         MapSet.member?(policy.blocked_actor_uris, candidate.actor_uri)) or
      domain_excluded?(policy.blocked_domains, candidate.actor_domain)
  end

  def maybe_filter_timeline_media(query, true) do
    from(m in query, where: fragment("array_length(?, 1) > 0", m.media_urls))
  end

  def maybe_filter_timeline_media(query, _only_media), do: query

  def maybe_apply_timeline_search(nil, _), do: nil

  def maybe_apply_timeline_search(query, search_query) when is_binary(search_query) do
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

  def maybe_apply_timeline_search(query, _), do: query

  def get_following_user_ids(user_id) do
    following =
      from(f in Follow,
        where: f.follower_id == ^user_id,
        select: f.followed_id
      )
      |> Repo.all()

    # Include self so your own posts always appear in your feed
    [user_id | following] |> Enum.uniq()
  end
end
