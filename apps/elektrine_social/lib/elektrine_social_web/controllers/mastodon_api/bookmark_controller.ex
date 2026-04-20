defmodule ElektrineSocialWeb.MastodonAPI.BookmarkController do
  @moduledoc """
  Mastodon-compatible bookmark listing.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Social
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def index(%{assigns: %{user: user}} = conn, params) do
    posts =
      Social.get_saved_posts(user.id, limit: parse_limit(params["limit"], 20))
      |> StatusView.render_statuses(user)

    json(conn, posts)
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> min(max(int, 1), 40)
      _ -> default
    end
  end
end
