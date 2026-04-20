defmodule ElektrineSocialWeb.MastodonAPI.MetaController do
  @moduledoc """
  Mastodon-compatible metadata endpoints and safe defaults for client-state APIs.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Emojis
  alias Elektrine.Social

  def custom_emojis(conn, _params) do
    emojis =
      Emojis.list_all_emojis(limit: 200, filter: "enabled")
      |> Enum.map(fn emoji ->
        %{
          shortcode: emoji.shortcode,
          url: emoji.image_url,
          static_url: emoji.image_url,
          visible_in_picker: true,
          category: emoji.category
        }
      end)

    json(conn, emojis)
  end

  def announcements(conn, _params), do: json(conn, [])

  def trending_tags(conn, _params) do
    tags =
      Social.get_trending_hashtags(limit: 10)
      |> Enum.map(fn tag ->
        %{name: tag.name, url: "#{ElektrineWeb.Endpoint.url()}/tags/#{tag.name}", history: []}
      end)

    json(conn, tags)
  end

  def preferences(%{assigns: %{user: nil}} = conn, _params), do: json(conn, %{})

  def preferences(%{assigns: %{user: user}} = conn, _params) do
    json(conn, %{
      "posting:default:visibility" => user.default_post_visibility || "public",
      "posting:default:sensitive" => false,
      "posting:default:language" => user.locale || "en",
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false,
      "notifications:follow" => user.notify_on_new_follower,
      "notifications:favourite" => user.notify_on_like,
      "notifications:mention" => user.notify_on_mention,
      "notifications:reblog" => true,
      "notifications:poll" => true
    })
  end

  def markers(conn, _params), do: json(conn, %{})
  def save_markers(conn, _params), do: json(conn, %{})
  def filters_v1(conn, _params), do: json(conn, [])
  def filters_v2(conn, _params), do: json(conn, [])
  def create_filter(conn, _params), do: json(conn, %{})
  def update_filter(conn, _params), do: json(conn, %{})
  def delete_filter(conn, _params), do: json(conn, %{})

  def create_push_subscription(conn, _params), do: json(conn, push_subscription())
  def show_push_subscription(conn, _params), do: json(conn, push_subscription())
  def update_push_subscription(conn, _params), do: json(conn, push_subscription())
  def delete_push_subscription(conn, _params), do: json(conn, %{})

  defp push_subscription do
    %{
      id: "default",
      endpoint: nil,
      alerts: %{follow: true, favourite: true, reblog: true, mention: true, poll: true}
    }
  end
end
