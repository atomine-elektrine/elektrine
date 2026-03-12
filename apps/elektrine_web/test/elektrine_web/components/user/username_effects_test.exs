defmodule ElektrineWeb.Components.User.UsernameEffectsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.User.UsernameEffects

  test "renders remote dm search result maps without a profile key" do
    user = %{
      handle: "support@onegold.com",
      id: nil,
      username: "support",
      avatar: nil,
      display_name: "@support@onegold.com",
      remote_handle: "support@onegold.com"
    }

    html =
      render_component(&UsernameEffects.username_with_effects/1,
        user: user,
        display_name: true,
        verified_size: "xs"
      )

    assert html =~ "@support@onegold.com"
  end
end
