defmodule ElektrineWeb.Components.EmojiPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Emojis.CustomEmoji
  alias ElektrineWeb.Components.EmojiPicker

  test "filters unsafe custom emoji image URLs" do
    html =
      render_component(&EmojiPicker.emoji_picker/1,
        id: "emoji-picker",
        on_select: "insert_emoji",
        active_tab: "Custom",
        custom_emojis: [
          %CustomEmoji{
            shortcode: "badcat",
            image_url: "javascript:alert(1)"
          },
          %CustomEmoji{
            shortcode: "safe_cat",
            image_url: "https://example.com/emojis/safe-cat.png"
          }
        ]
      )

    refute html =~ "badcat"
    refute html =~ "javascript:"
    assert html =~ "safe_cat"
    assert html =~ ~s|src="https://example.com/emojis/safe-cat.png"|
  end

  test "filters unsafe custom emoji search results" do
    html =
      render_component(&EmojiPicker.emoji_picker/1,
        id: "emoji-picker",
        on_select: "insert_emoji",
        search_query: "cat",
        custom_emojis: [
          %CustomEmoji{
            shortcode: "badcat",
            image_url: "https://example.com\r\nLocation:https://evil.test"
          }
        ]
      )

    refute html =~ "badcat"
    refute html =~ "evil.test"
    assert html =~ "No emojis found"
  end
end
