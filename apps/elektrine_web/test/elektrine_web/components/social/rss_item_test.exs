defmodule ElektrineWeb.Components.Social.RSSItemTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineSocialWeb.Components.Social.RSSItem

  test "renders safe RSS item URLs" do
    html =
      render_component(&RSSItem.rss_item/1,
        item:
          rss_item(%{
            url: "https://news.example/article",
            image_url: "https://news.example/image.jpg",
            feed_favicon_url: "https://news.example/favicon.ico",
            feed_site_url: "https://news.example/"
          })
      )

    assert html =~ ~s|href="https://news.example/article"|
    assert html =~ ~s|src="https://news.example/image.jpg"|
    assert html =~ ~s|src="https://news.example/favicon.ico"|
    assert html =~ ~s|href="https://news.example/"|
  end

  test "omits unsafe RSS item URLs and images" do
    html =
      render_component(&RSSItem.rss_item/1,
        item:
          rss_item(%{
            url: "javascript:alert(1)",
            image_url: "https://example.com\r\nLocation:https://evil.test",
            feed_favicon_url: "https://user:pass@example.com/favicon.ico",
            feed_site_url: "//evil.test/"
          })
      )

    assert html =~ "RSS Title"
    refute html =~ "javascript:"
    refute html =~ "evil.test"
    refute html =~ "user:pass"
    refute html =~ "<img"
  end

  defp rss_item(attrs) do
    Map.merge(
      %{
        id: 123,
        title: "RSS Title",
        url: "https://news.example/article",
        feed_title: "News",
        feed_favicon_url: nil,
        feed_site_url: nil,
        image_url: nil,
        summary: nil,
        content: nil,
        categories: [],
        published_at: ~U[2026-06-24 00:00:00Z],
        inserted_at: ~U[2026-06-24 00:00:00Z]
      },
      attrs
    )
  end
end
