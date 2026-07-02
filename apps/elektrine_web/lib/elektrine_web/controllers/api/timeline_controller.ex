defmodule ElektrineWeb.API.TimelineController do
  @moduledoc """
  Standard timeline endpoints for API clients.
  """
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.{PaginationHeaders, StatusJSON}
  alias ElektrineWeb.Platform.Integrations

  def home(conn, params) do
    user = conn.assigns[:current_user]
    opts = timeline_opts(params, user.id)

    posts = Integrations.social_combined_feed(user.id, opts)

    conn
    |> PaginationHeaders.put_pagination_links(posts, params)
    |> json(StatusJSON.format_statuses(posts, user.id))
  end

  def direct(conn, params) do
    user = conn.assigns[:current_user]
    opts = timeline_opts(params, user.id)

    posts = Integrations.social_direct_timeline(user.id, opts)

    conn
    |> PaginationHeaders.put_pagination_links(posts, params)
    |> json(StatusJSON.format_statuses(posts, user.id))
  end

  def public(conn, params) do
    user = conn.assigns[:current_user]
    opts = timeline_opts(params, user.id)

    posts =
      if truthy?(params["local"]) do
        Integrations.social_local_timeline(opts)
      else
        Integrations.social_public_timeline(opts)
      end

    conn
    |> PaginationHeaders.put_pagination_links(posts, params)
    |> json(StatusJSON.format_statuses(posts, user.id))
  end

  defp timeline_opts(params, user_id) do
    [
      user_id: user_id,
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"]),
      only_media: truthy_opt(params["only_media"]),
      search_query: text_param(params["q"]) || text_param(params["search"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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

  defp text_param(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text_param(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp truthy_opt(value) do
    if truthy?(value), do: true
  end
end
