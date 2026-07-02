defmodule ElektrineWeb.API.AccountSearchController do
  @moduledoc """
  API endpoints for account lookup and account search.
  """
  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.API.RelationshipJSON

  action_fallback ElektrineWeb.FallbackController

  @default_limit 20
  @max_limit 80

  def show(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case resolve_account_id(id) do
      %User{} = user ->
        json(conn, format_account(user, viewer, params))

      %Actor{} = actor ->
        json(conn, format_account(actor, viewer, params))

      nil ->
        not_found(conn)
    end
  end

  def lookup(conn, params) do
    viewer = conn.assigns[:current_user]
    identifier = params["acct"] || params["uri"] || params["username"] || params["q"]

    case lookup_account(identifier) do
      %User{} = user ->
        json(conn, format_account(user, viewer, params))

      %Actor{} = actor ->
        json(conn, format_account(actor, viewer, params))

      nil ->
        not_found(conn)
    end
  end

  def search(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_limit(params["limit"])
    query = normalize_query(params["q"] || params["acct"] || params["query"])

    accounts =
      if query == "" do
        []
      else
        query
        |> search_accounts(user.id, limit)
        |> format_accounts(user, params)
      end

    json(conn, accounts)
  end

  defp format_account(account, viewer, params) do
    account
    |> AccountJSON.format_account(viewer)
    |> maybe_embed_relationship(viewer, account, params)
  end

  defp format_accounts(accounts, viewer, params) do
    formatted = AccountJSON.format_accounts(accounts, viewer)

    if truthy?(params["with_relationships"]) do
      formatted
      |> Enum.zip(accounts)
      |> Enum.map(fn {payload, account} ->
        maybe_embed_relationship(payload, viewer, account, params)
      end)
    else
      formatted
    end
  end

  defp maybe_embed_relationship(payload, %{id: viewer_id}, account, params) do
    if truthy?(params["with_relationships"]) do
      RelationshipJSON.embed_relationship(payload, viewer_id, account)
    else
      payload
    end
  end

  defp maybe_embed_relationship(payload, _viewer, _account, _params), do: payload

  defp search_accounts(query, viewer_id, limit) do
    (search_local_accounts(query, viewer_id, limit) ++ search_remote_accounts(query, limit))
    |> Enum.reject(&account_filtered?(&1, viewer_id))
    |> Enum.uniq_by(&account_key/1)
    |> Enum.take(limit)
  end

  defp search_local_accounts(query, viewer_id, limit) do
    like_query = like_query(query)

    from(user in User,
      where: user.id != ^viewer_id,
      where: user.banned != true and user.suspended != true,
      where: user.profile_visibility != "private",
      where:
        fragment("LOWER(?) LIKE ?", user.username, ^like_query) or
          fragment("LOWER(?) LIKE ?", user.display_name, ^like_query) or
          fragment("LOWER(?) LIKE ?", user.handle, ^like_query),
      order_by: [
        asc: fragment("CASE WHEN LOWER(?) = ? THEN 0 ELSE 1 END", user.handle, ^query),
        asc: user.username
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp search_remote_accounts(query, limit) do
    like_query = like_query(query)

    from(actor in Actor,
      where:
        fragment("LOWER(?) LIKE ?", actor.username, ^like_query) or
          fragment("LOWER(?) LIKE ?", actor.display_name, ^like_query) or
          fragment("LOWER(?) LIKE ?", actor.domain, ^like_query) or
          fragment("LOWER(CONCAT(?, '@', ?)) LIKE ?", actor.username, actor.domain, ^like_query),
      order_by: [
        asc:
          fragment(
            "CASE WHEN LOWER(CONCAT(?, '@', ?)) = ? THEN 0 ELSE 1 END",
            actor.username,
            actor.domain,
            ^query
          ),
        asc: actor.domain,
        asc: actor.username
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp account_filtered?(%User{id: user_id}, viewer_id) when is_integer(viewer_id) do
    Accounts.user_muted?(viewer_id, user_id) or
      Accounts.user_blocked?(viewer_id, user_id) or
      Accounts.user_blocked?(user_id, viewer_id)
  end

  defp account_filtered?(%Actor{id: actor_id, domain: domain}, viewer_id)
       when is_integer(viewer_id) do
    Accounts.remote_actor_muted?(viewer_id, actor_id) or
      Accounts.remote_actor_blocked?(viewer_id, actor_id) or
      Accounts.domain_blocked?(viewer_id, domain)
  end

  defp account_filtered?(_account, _viewer_id), do: false

  defp lookup_account(identifier) do
    case normalize_identifier(identifier) do
      "" ->
        nil

      normalized ->
        lookup_local_account(normalized) || lookup_remote_account(normalized)
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
        Repo.one(
          from(actor in Actor,
            where: actor.uri == ^identifier,
            limit: 1
          )
        )
    end
  end

  defp resolve_account_id("remote:" <> id), do: get_actor(id)

  defp resolve_account_id(id) do
    get_user(id) || get_actor(id)
  end

  defp get_user(id) do
    Repo.get(User, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp get_actor(id) do
    Repo.get(Actor, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp account_key(%User{id: id}), do: {:user, id}
  defp account_key(%Actor{id: id}), do: {:actor, id}

  defp normalize_query(value) do
    value
    |> normalize_identifier()
    |> Elektrine.TextHelpers.sanitize_search_term()
    |> String.downcase()
  end

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp normalize_identifier(_value), do: ""

  defp like_query(query), do: "%#{String.downcase(query)}%"

  defp split_handle(identifier) do
    case String.split(identifier, "@", parts: 2) do
      [name, domain] when name != "" and domain != "" -> {name, domain}
      _ -> :local
    end
  end

  defp local_domain?(domain) when is_binary(domain),
    do: Elektrine.Domains.local_profile_domain?(domain)

  defp local_domain?(_domain), do: false

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> parse_limit(limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "account not found"})
  end
end
