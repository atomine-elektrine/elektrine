defmodule ElektrineSocialWeb.MastodonAPI.SearchController do
  @moduledoc """
  Mastodon-compatible search endpoint backed by Elektrine user, hashtag, and public post search.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Social
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  def index_v1(conn, params), do: search(conn, params)
  def index_v2(conn, params), do: search(conn, params)

  defp search(conn, %{"q" => query} = params) do
    viewer = conn.assigns[:user]
    limit = parse_limit(params["limit"], 5)
    type = params["type"]

    accounts = if is_nil(type) or type == "accounts", do: search_accounts(query, viewer), else: []

    statuses =
      if is_nil(type) or type == "statuses", do: search_statuses(query, viewer, limit), else: []

    hashtags = if is_nil(type) or type == "hashtags", do: search_hashtags(query, limit), else: []

    json(conn, %{accounts: accounts, statuses: statuses, hashtags: hashtags})
  end

  defp search(conn, _params), do: json(conn, %{accounts: [], statuses: [], hashtags: []})

  defp search_accounts(query, %{id: user_id} = viewer) do
    Accounts.search_users(query, user_id)
    |> StatusView.render_accounts(viewer)
  end

  defp search_accounts(_query, _viewer), do: []

  defp search_statuses(query, viewer, limit) do
    [limit: limit, search_query: query, user_id: viewer && viewer.id]
    |> Social.get_public_timeline()
    |> StatusView.render_statuses(viewer)
  end

  defp search_hashtags(query, limit) do
    Social.search_hashtags(query, limit)
    |> Enum.map(fn hashtag ->
      %{
        name: hashtag.name,
        url: "#{ElektrineWeb.Endpoint.url()}/tags/#{hashtag.name}",
        history: []
      }
    end)
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> min(max(int, 1), 20)
      _ -> default
    end
  end
end
