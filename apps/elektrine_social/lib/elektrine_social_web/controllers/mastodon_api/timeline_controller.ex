defmodule ElektrineSocialWeb.MastodonAPI.TimelineController do
  @moduledoc """
  Mastodon-compatible timeline endpoints backed by Elektrine's social feeds.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Social
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def home(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def home(%{assigns: %{user: user}} = conn, params) do
    posts =
      user.id
      |> Social.get_timeline_feed(timeline_opts(params))
      |> StatusView.render_statuses(user)

    json(conn, posts)
  end

  def public(conn, params) do
    viewer = conn.assigns[:user]
    user_id = viewer && viewer.id

    posts =
      ([user_id: user_id] ++ timeline_opts(params))
      |> Social.get_public_timeline()
      |> StatusView.render_statuses(viewer)

    json(conn, posts)
  end

  def tag(conn, %{"hashtag" => hashtag} = params) do
    viewer = conn.assigns[:user]

    posts =
      hashtag
      |> Social.get_posts_for_hashtag(hashtag_opts(params))
      |> StatusView.render_statuses(viewer)

    json(conn, posts)
  end

  defp timeline_opts(params) do
    limit = parse_limit(params["limit"], 20)

    []
    |> maybe_put(:limit, limit)
    |> maybe_put(:before_id, parse_int(params["max_id"]))
    |> maybe_put(:min_id, parse_int(params["min_id"]))
    |> maybe_put(:since_id, parse_int(params["since_id"]))
  end

  defp hashtag_opts(params) do
    []
    |> maybe_put(:limit, parse_limit(params["limit"], 20))
    |> maybe_put(:before_id, parse_int(params["max_id"]))
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    value
    |> parse_int()
    |> case do
      nil -> default
      int -> min(max(int, 1), 40)
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
