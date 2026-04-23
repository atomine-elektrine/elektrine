defmodule ElektrineSocialWeb.MastodonAPI.FavouriteController do
  @moduledoc """
  Mastodon-compatible favourites listing.
  """

  use ElektrineSocialWeb, :controller

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.PostLike
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def index(%{assigns: %{user: user}} = conn, params) do
    limit = parse_limit(params["limit"], 20)

    posts =
      from(l in PostLike,
        where: l.user_id == ^user.id,
        join: m in Message,
        on: m.id == l.message_id,
        where: is_nil(m.deleted_at),
        order_by: [desc: l.created_at],
        limit: ^limit,
        preload: [message: [sender: [:profile], conversation: [], hashtags: [], remote_actor: []]]
      )
      |> Repo.all()
      |> Enum.map(& &1.message)
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
