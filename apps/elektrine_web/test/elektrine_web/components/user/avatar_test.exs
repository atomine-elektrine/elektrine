defmodule ElektrineWeb.Components.User.AvatarTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.User.Avatar

  describe "conversation_avatar/1" do
    test "does not render unsafe conversation avatar URLs" do
      html =
        render_component(&Avatar.conversation_avatar/1,
          conversation: %{
            type: "group",
            name: "Unsafe",
            avatar_url: "javascript:alert(1)"
          },
          current_user_id: 1
        )

      refute html =~ "javascript:"
      refute html =~ "<img"
    end

    test "does not render arbitrary local absolute conversation avatar paths" do
      html =
        render_component(&Avatar.conversation_avatar/1,
          conversation: %{
            type: "group",
            name: "Unsafe",
            avatar_url: "/admin/internal.png"
          },
          current_user_id: 1
        )

      refute html =~ "/admin/internal.png"
      refute html =~ "<img"
    end

    test "renders relative upload conversation avatar paths" do
      html =
        render_component(&Avatar.conversation_avatar/1,
          conversation: %{
            type: "group",
            name: "Safe",
            avatar_url: "uploads/avatars/group.png"
          },
          current_user_id: 1
        )

      assert html =~ ~s(src="/uploads/avatars/group.png")
    end
  end
end
