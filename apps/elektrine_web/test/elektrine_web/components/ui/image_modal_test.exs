defmodule ElektrineWeb.Components.UI.ImageModalTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.UI.ImageModal

  describe "image_modal/1" do
    test "does not render unsafe media URLs" do
      html =
        render_component(&ImageModal.image_modal/1,
          show: true,
          image_url: "javascript:alert(1)",
          images: [],
          post: nil
        )

      refute html =~ "javascript:"
      refute html =~ ~s(src=)
    end

    test "does not render arbitrary local paths" do
      html =
        render_component(&ImageModal.image_modal/1,
          show: true,
          image_url: "/admin/internal.png",
          images: [],
          post: nil
        )

      refute html =~ "/admin/internal.png"
      refute html =~ ~s(src=)
    end

    test "renders relative upload media paths" do
      html =
        render_component(&ImageModal.image_modal/1,
          show: true,
          image_url: "uploads/timeline-attachments/post.png",
          images: [],
          post: nil
        )

      assert html =~ ~s(src="/uploads/timeline-attachments/post.png")
    end

    test "renders safe public HTTPS media URLs" do
      html =
        render_component(&ImageModal.image_modal/1,
          show: true,
          image_url: "https://example.com/video.mp4",
          images: [],
          post: nil
        )

      assert html =~ ~s(<video)
      assert html =~ ~s(src="https://example.com/video.mp4")
    end
  end
end
