defmodule ElektrineWeb.Components.Social.RemotePostSharedTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineSocialWeb.Components.Social.RemotePostShared

  test "media attachments render extensionless video links by media type" do
    video_url = "https://peertube.example/download/stream"
    preview_url = "https://peertube.example/lazy-static/previews/video.jpg"

    html =
      render_component(&RemotePostShared.media_attachments/1,
        attachments: [
          %{
            "type" => "video",
            "mediaType" => "video/mp4",
            "url" => video_url,
            "preview_url" => preview_url,
            "name" => "PeerTube video"
          }
        ],
        layout: :single
      )

    assert html =~ "<video"
    assert html =~ ~s(src="#{video_url}")
    assert html =~ ~s(poster="#{preview_url}")
    refute html =~ ~s(<img src="#{video_url}")
  end

  test "media attachments keep images zoomable" do
    image_url = "https://remote.example/media/photo.jpg"

    html =
      render_component(&RemotePostShared.media_attachments/1,
        attachments: [%{"type" => "Image", "mediaType" => "image/jpeg", "url" => image_url}],
        post_id: "https://remote.example/posts/1"
      )

    assert html =~ ~s(phx-click="open_image_modal")
    assert html =~ ~s(src="#{image_url}")
    assert html =~ ~s(phx-value-post_id="https://remote.example/posts/1")
  end
end
