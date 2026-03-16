defmodule Elektrine.EmojisTest do
  use Elektrine.DataCase

  alias Elektrine.Emojis
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo

  describe "get_or_create_from_activitypub/2" do
    test "rejects unsafe image URLs" do
      emoji_data = %{
        "type" => "Emoji",
        "name" => ":blobcat:",
        "icon" => %{
          "url" => ~s|https://cdn.example/emojis/blobcat.png" onerror="alert(1)|
        }
      }

      assert {:error, changeset} =
               Emojis.get_or_create_from_activitypub(emoji_data, "remote.example")

      assert "must be a valid public http(s) URL" in errors_on(changeset).image_url
    end
  end

  describe "render_custom_emojis/2" do
    test "does not render stored emojis with unsafe image URLs" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(CustomEmoji, [
        %{
          shortcode: "blobcat",
          image_url: ~s|https://cdn.example/emojis/blobcat.png" onerror="alert(1)|,
          instance_domain: "remote.example",
          visible_in_picker: false,
          disabled: false,
          inserted_at: now,
          updated_at: now
        }
      ])

      assert {"hello :blobcat:", []} =
               Emojis.render_custom_emojis("hello :blobcat:", "remote.example")
    end

    test "renders local emojis when the caller passes the local instance hostname" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(CustomEmoji, [
        %{
          shortcode: "thumbsupcat",
          image_url: "https://cdn.example/emojis/thumbsupcat.png",
          instance_domain: nil,
          visible_in_picker: false,
          disabled: false,
          inserted_at: now,
          updated_at: now
        }
      ])

      {html, emojis} =
        Emojis.render_custom_emojis(
          "hello :thumbsupcat:",
          Elektrine.Domains.instance_domain()
        )

      assert length(emojis) == 1
      assert html =~ "custom-emoji"
      assert html =~ "thumbsupcat.png"
    end

    test "returns the shortcode for unsafe inline emoji rows" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(CustomEmoji, [
        %{
          shortcode: "blobcat",
          image_url: "http://127.0.0.1/blobcat.png",
          instance_domain: nil,
          visible_in_picker: true,
          disabled: false,
          inserted_at: now,
          updated_at: now
        }
      ])

      assert Emojis.render_emoji_html(":blobcat:") == ":blobcat:"
    end
  end
end
