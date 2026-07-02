defmodule ElektrineWeb.API.TagController do
  @moduledoc """
  Tag discovery and follow controls for API clients.
  """
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.{PaginationHeaders, StatusJSON}
  alias ElektrineWeb.Platform.Integrations

  def index_followed(conn, _params) do
    user = conn.assigns[:current_user]

    tags =
      user.id
      |> Integrations.social_list_followed_hashtags()
      |> Enum.map(&tag_json(&1, true))

    json(conn, tags)
  end

  def show(conn, %{"id" => tag_name}) do
    user = conn.assigns[:current_user]
    normalized_name = normalize_tag_name(tag_name)

    case Integrations.social_get_hashtag_by_normalized_name(normalized_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "tag not found"})

      tag ->
        json(
          conn,
          tag_json(tag, Integrations.social_following_hashtag?(user.id, normalized_name))
        )
    end
  end

  def follow(conn, %{"id" => tag_name}) do
    user = conn.assigns[:current_user]

    case Integrations.social_follow_hashtag(user.id, tag_name) do
      {:ok, _follow} ->
        normalized_name = normalize_tag_name(tag_name)
        tag = Integrations.social_get_hashtag_by_normalized_name(normalized_name)
        json(conn, tag_json(tag, true))

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid tag"})
    end
  end

  def unfollow(conn, %{"id" => tag_name}) do
    user = conn.assigns[:current_user]
    normalized_name = normalize_tag_name(tag_name)
    :ok = Integrations.social_unfollow_hashtag(user.id, normalized_name)

    tag = Integrations.social_get_hashtag_by_normalized_name(normalized_name)
    json(conn, tag_json(tag, false, normalized_name))
  end

  def timeline(conn, %{"tag" => tag_name} = params) do
    user = conn.assigns[:current_user]
    normalized_name = normalize_tag_name(tag_name)
    opts = timeline_opts(params, user.id)

    posts = Integrations.social_get_posts_for_hashtag(normalized_name, opts)

    conn
    |> PaginationHeaders.put_pagination_links(posts, params)
    |> json(StatusJSON.format_statuses(posts, user.id))
  end

  defp tag_json(nil, following), do: tag_json(nil, following, "")
  defp tag_json(tag, following), do: tag_json(tag, following, nil)

  defp tag_json(nil, following, fallback_name) do
    %{
      name: fallback_name,
      url: tag_url(fallback_name),
      history: [],
      following: following
    }
  end

  defp tag_json(tag, following, _fallback_name) do
    name = tag.normalized_name || normalize_tag_name(tag.name)

    %{
      name: name,
      url: tag_url(name),
      history: [
        %{
          day: today_unix_day(),
          uses: tag.use_count || 0,
          accounts: Integrations.social_count_hashtag_followers(name)
        }
      ],
      following: following
    }
  end

  defp normalize_tag_name(tag_name) when is_binary(tag_name) do
    tag_name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp timeline_opts(params, user_id) do
    [
      user_id: user_id,
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"]),
      any_tags: tag_list_param(params["any"]),
      all_tags: tag_list_param(params["all"]),
      none_tags: tag_list_param(params["none"])
    ]
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      _entry -> false
    end)
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(value) do
    value
    |> positive_id()
    |> case do
      nil -> 20
      limit -> limit |> max(1) |> min(40)
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

  defp tag_list_param(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      item when is_binary(item) -> String.split(item, ",")
      _item -> []
    end)
    |> Enum.map(&normalize_tag_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp tag_url(name), do: ElektrineWeb.Endpoint.url() <> "/tags/" <> URI.encode(name)

  defp today_unix_day do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
    |> Integer.to_string()
  end
end
