defmodule ElektrineWeb.Components.Social.YoutubePreviewTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.Social.YoutubePreview

  test "rich link preview drops unsafe destination URLs" do
    html =
      render_component(&YoutubePreview.rich_link_preview/1,
        url: "javascript:alert(1)",
        preview: %{status: "success", title: "Bad", description: "Bad link"}
      )

    refute html =~ "javascript:"
    refute html =~ ~s|href=|
  end

  test "rich link preview filters unsafe image URLs" do
    html =
      render_component(&YoutubePreview.rich_link_preview/1,
        url: "https://example.com/post",
        preview: %{
          status: "success",
          title: "Good",
          description: "Bad images",
          image_url: "javascript:alert(1)",
          favicon_url: "data:image/png;base64,AAAA"
        }
      )

    assert html =~ ~s|href="https://example.com/post"|
    refute html =~ "javascript:"
    refute html =~ "data:image"
  end
end
