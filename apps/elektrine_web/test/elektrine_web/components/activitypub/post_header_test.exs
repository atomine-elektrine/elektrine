defmodule ElektrineWeb.Components.ActivityPub.PostHeaderTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.ActivityPub.PostHeader

  test "local post avatars render through the upload URL helper" do
    html =
      render_component(&PostHeader.post_author/1,
        post: %{
          federated: false,
          sender: %{
            avatar: "alice.png",
            username: "alice",
            handle: "alice",
            display_name: nil
          }
        }
      )

    assert html =~ ~s(src="/uploads/avatars/alice.png")
    refute html =~ ~s(src="alice.png")
  end
end
