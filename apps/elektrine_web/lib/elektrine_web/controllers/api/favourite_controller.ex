defmodule ElektrineWeb.API.FavouriteController do
  @moduledoc """
  API endpoint for the current user's favourited statuses.
  """
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.{PaginationHeaders, StatusJSON}
  alias ElektrineWeb.Platform.Integrations

  def index(conn, params) do
    user = conn.assigns[:current_user]
    opts = favourite_opts(params)

    posts = Integrations.social_liked_posts(user.id, opts)

    conn
    |> PaginationHeaders.put_pagination_links(posts, params)
    |> json(StatusJSON.format_statuses(posts, user.id))
  end

  defp favourite_opts(params) do
    [
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"]),
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
end
