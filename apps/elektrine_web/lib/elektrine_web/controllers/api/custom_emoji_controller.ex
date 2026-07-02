defmodule ElektrineWeb.API.CustomEmojiController do
  @moduledoc """
  JSON API for picker-visible custom emojis.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Emojis

  def index(conn, _params) do
    emojis =
      Emojis.list_public_picker_emojis()
      |> Enum.map(&format_emoji/1)

    json(conn, emojis)
  end

  defp format_emoji(emoji) do
    static_url = emoji.image_url

    %{
      shortcode: emoji.shortcode,
      url: emoji.image_url,
      static_url: static_url,
      visible_in_picker: emoji.visible_in_picker,
      category: emoji.category,
      tags: emoji_tags(emoji),
      instance_domain: emoji.instance_domain
    }
  end

  defp emoji_tags(%{category: category}) when is_binary(category) and category != "",
    do: [category]

  defp emoji_tags(_emoji), do: []
end
