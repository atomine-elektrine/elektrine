defmodule Elektrine.Social.TimelineRelationships do
  @moduledoc """
  Batch-loaded interaction state for timeline rendering.
  """

  import Ecto.Query

  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub.{Actor, UserBlock}
  alias Elektrine.Messaging.UserHiddenMessage
  alias Elektrine.Repo
  alias Elektrine.Social

  def load(nil, _posts), do: empty()

  def load(user_id, posts) when is_integer(user_id) and is_list(posts) do
    message_ids = message_ids(posts)
    sender_ids = sender_ids(posts)
    remote_actors = remote_actors_by_id(posts)
    muted_sender_ids = muted_sender_ids(user_id, sender_ids)
    hidden_message_ids = hidden_message_ids(user_id, message_ids)
    {blocked_actor_uris, muted_actor_uris, blocked_domains} = block_policy(user_id)

    %{
      likes: MapSet.new(Social.list_user_likes(user_id, message_ids)),
      boosts: MapSet.new(Social.list_user_boosts(user_id, message_ids)),
      saved: Social.list_user_saved_posts(user_id, message_ids),
      votes: Social.get_user_votes(user_id, message_ids),
      muted_sender_ids: muted_sender_ids,
      hidden_message_ids: hidden_message_ids,
      blocked_actor_uris: blocked_actor_uris,
      muted_actor_uris: muted_actor_uris,
      blocked_domains: blocked_domains,
      blocked_message_ids:
        blocked_message_ids(
          posts,
          muted_sender_ids,
          hidden_message_ids,
          blocked_actor_uris,
          muted_actor_uris,
          blocked_domains,
          remote_actors
        )
    }
  end

  def load(_, _), do: empty()

  def empty do
    %{
      likes: MapSet.new(),
      boosts: MapSet.new(),
      saved: MapSet.new(),
      votes: %{},
      muted_sender_ids: MapSet.new(),
      hidden_message_ids: MapSet.new(),
      blocked_actor_uris: MapSet.new(),
      muted_actor_uris: MapSet.new(),
      blocked_domains: compile_domain_policy([]),
      blocked_message_ids: MapSet.new()
    }
  end

  def muted_message?(relationships, %{sender_id: sender_id}) when is_integer(sender_id) do
    MapSet.member?(relationships.muted_sender_ids, sender_id)
  end

  def muted_message?(relationships, post) do
    actor = remote_actor_for(post, %{})
    is_binary(actor.uri) and MapSet.member?(relationships.muted_actor_uris, actor.uri)
  end

  def hidden_message?(relationships, %{id: message_id}) when is_integer(message_id) do
    MapSet.member?(relationships.hidden_message_ids, message_id)
  end

  def hidden_message?(_relationships, _post), do: false

  def remote_blocked_message?(relationships, post) do
    actor = remote_actor_for(post, %{})

    (is_binary(actor.uri) and MapSet.member?(relationships.blocked_actor_uris, actor.uri)) or
      domain_blocked?(relationships.blocked_domains, actor.domain)
  end

  def blocked_message?(relationships, post) do
    hidden_message?(relationships, post) or
      muted_message?(relationships, post) or
      remote_blocked_message?(relationships, post)
  end

  def blocked_message_except_mutes?(relationships, post) do
    hidden_message?(relationships, post) or remote_blocked_message?(relationships, post)
  end

  defp message_ids(posts) do
    posts
    |> Enum.map(fn
      %{id: id} when is_integer(id) -> id
      id when is_integer(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp sender_ids(posts) do
    posts
    |> Enum.map(fn
      %{sender_id: id} when is_integer(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp muted_sender_ids(_user_id, []), do: MapSet.new()

  defp muted_sender_ids(user_id, sender_ids) do
    Repo.all(
      from m in UserMute,
        where: m.muter_id == ^user_id and m.muted_id in ^sender_ids,
        select: m.muted_id
    )
    |> MapSet.new()
  end

  defp hidden_message_ids(_user_id, []), do: MapSet.new()

  defp hidden_message_ids(user_id, message_ids) do
    Repo.all(
      from h in UserHiddenMessage,
        where: h.user_id == ^user_id and h.message_id in ^message_ids,
        select: h.message_id
    )
    |> MapSet.new()
  end

  defp block_policy(user_id) do
    blocks =
      Repo.all(
        from b in UserBlock,
          where: b.user_id == ^user_id,
          select: {b.block_type, b.blocked_uri}
      )

    blocked_actor_uris =
      blocks
      |> Enum.filter(fn {type, uri} -> type == "user" and is_binary(uri) end)
      |> Enum.map(fn {_type, uri} -> uri end)
      |> MapSet.new()

    muted_actor_uris =
      blocks
      |> Enum.filter(fn {type, uri} -> type == "mute" and is_binary(uri) end)
      |> Enum.map(fn {_type, uri} -> uri end)
      |> MapSet.new()

    blocked_domains =
      blocks
      |> Enum.filter(fn {type, domain} -> type == "domain" and is_binary(domain) end)
      |> Enum.map(fn {_type, domain} -> domain end)
      |> compile_domain_policy()

    {blocked_actor_uris, muted_actor_uris, blocked_domains}
  end

  defp remote_actors_by_id(posts) do
    actor_ids =
      posts
      |> Enum.map(fn
        %{remote_actor_id: id} when is_integer(id) -> id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if actor_ids == [] do
      %{}
    else
      Repo.all(
        from a in Actor,
          where: a.id in ^actor_ids,
          select: {a.id, %{uri: a.uri, domain: a.domain}}
      )
      |> Map.new()
    end
  end

  defp blocked_message_ids(
         posts,
         muted_sender_ids,
         hidden_message_ids,
         blocked_actor_uris,
         muted_actor_uris,
         blocked_domains,
         remote_actors
       ) do
    Enum.reduce(posts, MapSet.new(), fn
      %{id: id} = post, acc when is_integer(id) ->
        if blocked_post?(
             post,
             muted_sender_ids,
             hidden_message_ids,
             blocked_actor_uris,
             muted_actor_uris,
             blocked_domains,
             remote_actors
           ) do
          MapSet.put(acc, id)
        else
          acc
        end

      _post, acc ->
        acc
    end)
  end

  defp blocked_post?(
         post,
         muted_sender_ids,
         hidden_message_ids,
         blocked_actor_uris,
         muted_actor_uris,
         blocked_domains,
         remote_actors
       ) do
    actor = remote_actor_for(post, remote_actors)

    MapSet.member?(hidden_message_ids, Map.get(post, :id)) or
      MapSet.member?(muted_sender_ids, Map.get(post, :sender_id)) or
      (is_binary(actor.uri) and MapSet.member?(muted_actor_uris, actor.uri)) or
      (is_binary(actor.uri) and MapSet.member?(blocked_actor_uris, actor.uri)) or
      domain_blocked?(blocked_domains, actor.domain)
  end

  defp remote_actor_for(%{remote_actor: %{uri: uri, domain: domain}}, _remote_actors),
    do: %{uri: uri, domain: domain}

  defp remote_actor_for(%{remote_actor_id: id}, remote_actors) when is_integer(id),
    do: Map.get(remote_actors, id, %{uri: nil, domain: nil})

  defp remote_actor_for(_, _remote_actors), do: %{uri: nil, domain: nil}

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

  defp domain_blocked?(%{exact: exact, wildcard_suffixes: suffixes}, domain)
       when is_binary(domain) do
    domain = String.downcase(domain)

    MapSet.member?(exact, domain) or Enum.any?(suffixes, &String.ends_with?(domain, &1))
  end

  defp domain_blocked?(_policy, _domain), do: false
end
