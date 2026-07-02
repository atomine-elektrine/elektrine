defmodule ElektrineWeb.API.SearchController do
  @moduledoc """
  API-compatible search endpoint for accounts, statuses, and hashtags.
  """

  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.API.StatusJSON
  alias ElektrineWeb.Platform.Integrations

  @default_limit 20
  @max_limit 40

  def index(conn, params) do
    user = conn.assigns[:current_user]
    query = normalize_query(params["q"])
    type = normalize_type(params["type"])
    limit = parse_limit(params["limit"])

    result =
      if query == "" do
        empty_result()
      else
        %{
          accounts:
            maybe_search(type, :accounts, fn -> search_accounts(query, user.id, limit) end),
          statuses:
            maybe_search(type, :statuses, fn -> search_statuses(query, user.id, limit) end),
          hashtags:
            maybe_search(type, :hashtags, fn -> search_hashtags(query, user.id, limit) end)
        }
      end

    json(conn, result)
  end

  defp maybe_search(nil, _bucket, fun), do: fun.()
  defp maybe_search(bucket, bucket, fun), do: fun.()
  defp maybe_search(_type, _bucket, _fun), do: []

  defp empty_result, do: %{accounts: [], statuses: [], hashtags: []}

  defp search_accounts(query, viewer_id, limit) do
    (search_local_accounts(query, viewer_id, limit) ++ search_remote_accounts(query, limit))
    |> Enum.reject(&account_filtered?(&1, viewer_id))
    |> Enum.uniq_by(&account_key/1)
    |> Enum.take(limit)
    |> AccountJSON.format_accounts(viewer_id)
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

  defp search_statuses(query, viewer_id, limit) do
    opts = [user_id: viewer_id, limit: limit, search_query: query]

    opts
    |> Integrations.social_public_timeline()
    |> StatusJSON.format_statuses(viewer_id)
  end

  defp search_hashtags(query, viewer_id, limit) do
    query
    |> Integrations.social_search_hashtags(limit)
    |> Enum.map(&format_hashtag(&1, viewer_id))
  end

  defp format_hashtag(tag, viewer_id) do
    name = tag.normalized_name || normalize_tag_name(tag.name)

    %{
      name: name,
      url: ElektrineWeb.Endpoint.url() <> "/tags/" <> URI.encode(name),
      history: [
        %{
          day: today_unix_day(),
          uses: tag.use_count || 0,
          accounts: Integrations.social_count_hashtag_followers(name)
        }
      ],
      following: Integrations.social_following_hashtag?(viewer_id, name)
    }
  end

  defp account_key(%User{id: id}), do: {:user, id}
  defp account_key(%Actor{id: id}), do: {:actor, id}

  defp normalize_query(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> Elektrine.TextHelpers.sanitize_search_term()
    |> String.downcase()
  end

  defp normalize_query(_value), do: ""

  defp normalize_tag_name(tag_name) when is_binary(tag_name) do
    tag_name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp normalize_type("accounts"), do: :accounts
  defp normalize_type("statuses"), do: :statuses
  defp normalize_type("hashtags"), do: :hashtags
  defp normalize_type(_type), do: nil

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) do
    value
    |> positive_id()
    |> case do
      nil -> @default_limit
      limit -> limit |> max(1) |> min(@max_limit)
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

  defp like_query(query), do: "%#{String.replace(query, "%", "\\%")}%"

  defp today_unix_day do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
    |> Integer.to_string()
  end
end
