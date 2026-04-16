defmodule Elektrine.Social.LinkPreviewTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_change: 2]

  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.LinkPreviewFetcher

  describe "changeset/2" do
    test "truncates long text fields and drops overlong URL fields" do
      long_title = String.duplicate("t", 300)
      long_site_name = String.duplicate("s", 300)
      long_image_url = "https://example.com/" <> String.duplicate("a", 3000)
      long_favicon_url = "https://example.com/" <> String.duplicate("b", 3000)

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          url: "https://example.com/post",
          title: long_title,
          site_name: long_site_name,
          image_url: long_image_url,
          favicon_url: long_favicon_url,
          status: "success"
        })

      assert changeset.valid?
      assert String.length(get_change(changeset, :title)) == 255
      assert String.length(get_change(changeset, :site_name)) == 255
      assert get_change(changeset, :image_url) == nil
      assert get_change(changeset, :favicon_url) == nil
    end

    test "keeps URL fields when they fit within varchar limits" do
      image_url = "https://example.com/image.png"
      favicon_url = "https://example.com/favicon.ico"

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          url: "https://example.com/post",
          image_url: image_url,
          favicon_url: favicon_url,
          status: "success"
        })

      assert changeset.valid?
      assert get_change(changeset, :image_url) == image_url
      assert get_change(changeset, :favicon_url) == favicon_url
    end

    test "keeps long proxied image urls used by community previews" do
      image_url =
        "https://lemmy.zip/api/v3/image_proxy?url=https%3A%2F%2Flemmy.world%2Fpictrs%2Fimage%2Fe4082657-9086-4bbb-88f8-51207fc0bf05.jpeg"

      favicon_url =
        "https://lemmy.zip/api/v3/image_proxy?url=https%3A%2F%2Flemmy.ml%2Fpictrs%2Fimage%2F56568a56-5b8d-4683-83bd-fca8e15e47db.jpeg"

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          url: "https://example.com/post",
          image_url: image_url,
          favicon_url: favicon_url,
          status: "success"
        })

      assert changeset.valid?
      assert get_change(changeset, :image_url) == image_url
      assert get_change(changeset, :favicon_url) == favicon_url
    end
  end

  describe "extract_urls/1" do
    test "trims trailing punctuation from extracted URLs" do
      content =
        "See https://lemmy.zip/api/v3/image_proxy?url=https%3A%2F%2Flemmy.world%2Fpictrs%2Fimage%2Fabc.jpeg) and https://xkcd.com/1534/)."

      assert LinkPreviewFetcher.extract_urls(content) == [
               "https://lemmy.zip/api/v3/image_proxy?url=https%3A%2F%2Flemmy.world%2Fpictrs%2Fimage%2Fabc.jpeg",
               "https://xkcd.com/1534/"
             ]
    end
  end
end
