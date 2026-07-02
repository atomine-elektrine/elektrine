defmodule ElektrineWeb.API.CustomEmojiControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo
  alias ElektrineWeb.API.CustomEmojiController

  describe "index/2" do
    test "lists only enabled picker emojis with safe image URLs", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(CustomEmoji, [
        emoji_row("blobcat", "https://cdn.example/emojis/blobcat.png", true, false, now),
        emoji_row("hidden", "https://cdn.example/emojis/hidden.png", false, false, now),
        emoji_row("disabled", "https://cdn.example/emojis/disabled.png", true, true, now),
        emoji_row(
          "badurl",
          ~s|https://cdn.example/emojis/bad.png" onerror="alert(1)|,
          true,
          false,
          now
        )
      ])

      conn = CustomEmojiController.index(conn, %{})

      assert [
               %{
                 "shortcode" => "blobcat",
                 "url" => "https://cdn.example/emojis/blobcat.png",
                 "static_url" => "https://cdn.example/emojis/blobcat.png",
                 "visible_in_picker" => true,
                 "category" => "cats",
                 "tags" => ["cats"]
               }
             ] = json_response(conn, 200)
    end
  end

  defp emoji_row(shortcode, image_url, visible_in_picker, disabled, now) do
    %{
      shortcode: shortcode,
      image_url: image_url,
      instance_domain: nil,
      category: "cats",
      visible_in_picker: visible_in_picker,
      disabled: disabled,
      inserted_at: now,
      updated_at: now
    }
  end
end
