defmodule ElektrineWeb.API.AccountRelationshipController do
  @moduledoc """
  Mastodon/Pleroma-compatible account relationship endpoints.
  """
  use ElektrineWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.API.PaginationHeaders
  alias ElektrineWeb.API.RelationshipJSON

  action_fallback ElektrineWeb.FallbackController

  def mutes(conn, params) do
    user = conn.assigns[:current_user]
    accounts = Accounts.list_muted_users(user.id)

    json(conn, format_accounts(accounts, user, params))
  end

  def blocks(conn, params) do
    user = conn.assigns[:current_user]

    remote_accounts =
      user.id
      |> Accounts.list_blocked_remote_actors()
      |> Enum.map(&actor_for_block/1)
      |> Enum.reject(&is_nil/1)

    accounts = Accounts.list_blocked_users(user.id) ++ remote_accounts
    json(conn, format_accounts(accounts, user, params))
  end

  def endorsements(conn, params) do
    user = conn.assigns[:current_user]

    accounts =
      user.id
      |> Accounts.list_endorsed_accounts()

    json(conn, format_accounts(accounts, user, params))
  end

  def account_endorsements(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case resolve_account(id) do
      {:ok, account} ->
        accounts = endorsed_accounts_for(account)

        json(conn, format_accounts(accounts, viewer, params))

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def relationships(conn, params) do
    user = conn.assigns[:current_user]

    relationships =
      params
      |> relationship_ids()
      |> Enum.map(&relationship_for(user.id, &1))
      |> Enum.reject(&is_nil/1)

    json(conn, relationships)
  end

  def familiar_followers(conn, params) do
    user = conn.assigns[:current_user]

    entries =
      params
      |> relationship_ids()
      |> Enum.flat_map(fn id ->
        case resolve_local_account(id) do
          {:ok, %Accounts.User{} = target} ->
            accounts =
              if hidden_account_list?(target, user, :followers) do
                []
              else
                target.id
                |> Elektrine.Profiles.get_familiar_followers(user.id)
                |> AccountJSON.format_accounts(user)
              end

            [%{id: to_string(target.id), accounts: accounts}]

          {:error, :not_found} ->
            []
        end
      end)

    json(conn, entries)
  end

  def followers(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case resolve_local_account(id) do
      {:ok, %Accounts.User{} = target} ->
        accounts =
          if hidden_account_list?(target, viewer, :followers) do
            []
          else
            target.id
            |> Elektrine.Profiles.get_followers(account_list_opts(params))
            |> Enum.map(&follow_account/1)
            |> Enum.reject(&is_nil/1)
            |> format_accounts(viewer, params)
          end

        conn
        |> PaginationHeaders.put_pagination_links(accounts, Map.delete(params, "id"))
        |> json(accounts)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def following(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case resolve_local_account(id) do
      {:ok, %Accounts.User{} = target} ->
        accounts =
          if hidden_account_list?(target, viewer, :follows) do
            []
          else
            target.id
            |> Elektrine.Profiles.get_following(account_list_opts(params))
            |> Enum.map(&follow_account/1)
            |> Enum.reject(&is_nil/1)
            |> format_accounts(viewer, params)
          end

        conn
        |> PaginationHeaders.put_pagination_links(accounts, Map.delete(params, "id"))
        |> json(accounts)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp hidden_account_list?(%Accounts.User{id: id}, %Accounts.User{id: id}, _type), do: false
  defp hidden_account_list?(%Accounts.User{hide_followers: true}, _viewer, :followers), do: true
  defp hidden_account_list?(%Accounts.User{hide_follows: true}, _viewer, :follows), do: true
  defp hidden_account_list?(_target, _viewer, _type), do: false

  def follow_by_uri(conn, params) do
    user = conn.assigns[:current_user]
    identifier = params["uri"] || params["acct"] || params["id"]

    with {:ok, target} <- resolve_account_identifier(identifier),
         {:ok, relationship} <- follow_account(user.id, target) do
      json(conn, relationship)
    else
      {:error, :self_follow} -> bad_request(conn, "cannot follow yourself")
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> forbidden(conn, inspect(reason))
    end
  end

  def follow(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, relationship} <- follow_account(user.id, target) do
      json(conn, relationship)
    else
      {:error, :self_follow} -> bad_request(conn, "cannot follow yourself")
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> forbidden(conn, inspect(reason))
    end
  end

  def unfollow(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, relationship} <- unfollow_account(user.id, target) do
      json(conn, relationship)
    else
      {:error, :self_follow} -> bad_request(conn, "cannot unfollow yourself")
      {:error, :not_found} -> not_found(conn)
    end
  end

  def endorse(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, _endorsement} <- Accounts.endorse_account(user.id, target) do
      json(conn, relationship_for(user.id, account_identifier(target)))
    else
      {:error, :self_endorse} -> bad_request(conn, "cannot endorse yourself")
      {:error, :not_found} -> not_found(conn)
      {:error, changeset = %Ecto.Changeset{}} -> changeset_error(conn, changeset)
      {:error, reason} -> bad_request(conn, inspect(reason))
    end
  end

  def unendorse(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, _status} <- Accounts.unendorse_account(user.id, target) do
      json(conn, relationship_for(user.id, account_identifier(target)))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> bad_request(conn, inspect(reason))
    end
  end

  def subscribe(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, _subscription} <- Accounts.subscribe_to_account(user.id, target) do
      json(conn, relationship_for(user.id, account_identifier(target)))
    else
      {:error, :self_subscribe} -> bad_request(conn, "cannot subscribe to yourself")
      {:error, :not_found} -> not_found(conn)
      {:error, changeset = %Ecto.Changeset{}} -> changeset_error(conn, changeset)
      {:error, reason} -> bad_request(conn, inspect(reason))
    end
  end

  def unsubscribe(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, _status} <- Accounts.unsubscribe_from_account(user.id, target) do
      json(conn, relationship_for(user.id, account_identifier(target)))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> bad_request(conn, inspect(reason))
    end
  end

  def remove_from_followers(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, %Accounts.User{} = follower} <- resolve_local_account(id),
         {:ok, _status} <- Elektrine.Profiles.remove_follower(user.id, follower.id) do
      relationship =
        relationship_for(user.id, to_string(follower.id)) ||
          format_relationship(follower, following: false, followed_by: false)

      json(conn, relationship)
    else
      {:error, :invalid_follower} -> bad_request(conn, "cannot remove yourself from followers")
      {:error, :not_found} -> not_found(conn)
    end
  end

  def lists(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case resolve_account(id) do
      {:ok, target} ->
        lists =
          user.id
          |> social().list_user_lists_for_account(target)
          |> Enum.map(&format_list/1)

        json(conn, lists)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def mute(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, %Accounts.User{} = target} <- resolve_local_account(id),
         {:ok, _mute} <-
           Accounts.mute_user(
             user.id,
             target.id,
             truthy?(params["notifications"]),
             parse_duration(params["duration"])
           ) do
      json(conn, format_relationship(target, muting: true, blocking: false))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def unmute(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case resolve_local_account(id) do
      {:ok, %Accounts.User{} = target} ->
        _ = Accounts.unmute_user(user.id, target.id)
        json(conn, format_relationship(target, muting: false, blocking: false))

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def block(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, target} <- resolve_account(id),
         {:ok, _} <- block_target(user.id, target) do
      json(conn, format_relationship(target, muting: false, blocking: true))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> bad_request(conn, inspect(reason))
    end
  end

  def unblock(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case resolve_account(id) do
      {:ok, target} ->
        _ = unblock_target(user.id, target)
        json(conn, format_relationship(target, muting: false, blocking: false))

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp resolve_account("remote:" <> id) do
    case Repo.get(Actor, id) do
      %Actor{} = actor -> {:ok, actor}
      nil -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp resolve_account(id) do
    case resolve_local_account(id) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        case Repo.get(Actor, id) do
          %Actor{} = actor -> {:ok, actor}
          nil -> {:error, :not_found}
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp resolve_account_identifier(identifier) do
    case normalize_identifier(identifier) do
      "" ->
        {:error, :not_found}

      normalized ->
        case lookup_local_account(normalized) || lookup_remote_account(normalized) do
          nil -> {:error, :not_found}
          account -> {:ok, account}
        end
    end
  end

  defp lookup_local_account(identifier) do
    case split_handle(identifier) do
      {name, domain} ->
        if local_domain?(domain), do: Accounts.get_user_by_username_or_handle(name), else: nil

      :local ->
        Accounts.get_user_by_username_or_handle(identifier)
    end
  end

  defp lookup_remote_account(identifier) do
    case split_handle(identifier) do
      {name, domain} ->
        Repo.one(
          from(actor in Actor,
            where:
              fragment("LOWER(?)", actor.username) == ^String.downcase(name) and
                fragment("LOWER(?)", actor.domain) == ^String.downcase(domain),
            limit: 1
          )
        )

      :local ->
        Repo.one(from(actor in Actor, where: actor.uri == ^identifier, limit: 1))
    end
  end

  defp resolve_local_account(id) do
    case Repo.get(Accounts.User, id) do
      %Accounts.User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp block_target(user_id, %Accounts.User{} = target),
    do: Accounts.block_user(user_id, target.id)

  defp block_target(user_id, %Actor{} = target),
    do: Accounts.block_remote_actor(user_id, target.id)

  defp unblock_target(user_id, %Accounts.User{} = target),
    do: Accounts.unblock_user(user_id, target.id)

  defp unblock_target(user_id, %Actor{} = target),
    do: Accounts.unblock_remote_actor(user_id, target.id)

  defp follow_account(user_id, %Accounts.User{id: user_id}), do: {:error, :self_follow}

  defp follow_account(user_id, %Accounts.User{} = target) do
    case Elektrine.Profiles.follow_user(user_id, target.id) do
      {:ok, _follow} -> {:ok, relationship_for(user_id, to_string(target.id))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp follow_account(user_id, %Actor{} = target) do
    if Elektrine.Profiles.following_remote_actor_by_identity?(user_id, target) do
      {:ok, relationship_for(user_id, "remote:#{target.id}")}
    else
      case Elektrine.Profiles.follow_remote_actor(user_id, target.id) do
        {:ok, _follow} -> {:ok, relationship_for(user_id, "remote:#{target.id}")}
        {:error, :already_following} -> {:ok, relationship_for(user_id, "remote:#{target.id}")}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp unfollow_account(user_id, %Accounts.User{id: user_id}), do: {:error, :self_follow}

  defp unfollow_account(user_id, %Accounts.User{} = target) do
    case Elektrine.Profiles.unfollow_user(user_id, target.id) do
      {:ok, _status} -> {:ok, relationship_for(user_id, to_string(target.id))}
    end
  end

  defp unfollow_account(user_id, %Actor{} = target) do
    case Elektrine.Profiles.unfollow_remote_actor(user_id, target.id) do
      {:ok, _status} -> {:ok, relationship_for(user_id, "remote:#{target.id}")}
      {:error, :not_following} -> {:ok, relationship_for(user_id, "remote:#{target.id}")}
    end
  end

  defp actor_for_block(%{blocked_uri: uri}) when is_binary(uri) do
    Repo.one(from(a in Actor, where: a.uri == ^uri, limit: 1))
  end

  defp actor_for_block(_), do: nil

  defp follow_account(%{user: %Accounts.User{} = user}), do: user
  defp follow_account(%{remote_actor: %Actor{} = actor}), do: actor
  defp follow_account(_entry), do: nil

  defp account_identifier(account), do: RelationshipJSON.account_identifier(account)

  defp format_accounts(accounts, viewer, params) do
    formatted = AccountJSON.format_accounts(accounts, viewer)

    if truthy?(params["with_relationships"]) do
      formatted
      |> Enum.zip(accounts)
      |> Enum.map(fn {payload, account} ->
        RelationshipJSON.embed_relationship(payload, viewer.id, account)
      end)
    else
      formatted
    end
  end

  defp endorsed_accounts_for(%Accounts.User{} = account),
    do: Accounts.list_endorsed_accounts(account.id)

  defp endorsed_accounts_for(%Actor{}), do: []

  defp format_relationship(account, attrs) do
    RelationshipJSON.format_relationship(account, attrs)
  end

  defp relationship_for(viewer_id, id) do
    case resolve_account(id) do
      {:ok, account} ->
        RelationshipJSON.format_relationship(viewer_id, account)

      {:error, :not_found} ->
        nil
    end
  end

  defp format_list(list) do
    %{
      id: to_string(list.id),
      title: list.name,
      replies_policy: "list",
      exclusive: false,
      description: list.description,
      visibility: list.visibility,
      accounts_count: list_member_count(list)
    }
  end

  defp list_member_count(%{list_members: %Ecto.Association.NotLoaded{}}), do: 0
  defp list_member_count(%{list_members: members}) when is_list(members), do: length(members)
  defp list_member_count(_list), do: 0

  defp relationship_ids(params) do
    params
    |> Map.take(["id", "id[]", :id])
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      value when is_integer(value) -> [to_string(value)]
      _value -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_duration(value) when is_integer(value) and value > 0, do: value

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp parse_duration(_), do: nil

  defp account_list_opts(params) do
    [
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"]),
      offset: non_negative_id(params["offset"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(value) do
    value
    |> positive_id()
    |> case do
      nil -> 20
      limit -> limit |> max(1) |> min(80)
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: value

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp non_negative_id(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> id
      _ -> nil
    end
  end

  defp non_negative_id(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> String.trim_leading("acct:")
  end

  defp normalize_identifier(_value), do: ""

  defp split_handle(identifier) do
    case String.split(identifier, "@", parts: 2) do
      [name, domain] when name != "" and domain != "" -> {name, domain}
      _ -> :local
    end
  end

  defp local_domain?(domain) when is_binary(domain),
    do: Elektrine.Domains.local_profile_domain?(domain)

  defp local_domain?(_domain), do: false

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "account not found"})
  end

  defp bad_request(conn, error) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: error})
  end

  defp forbidden(conn, error) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: error})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
