defmodule ElektrineWeb.Components.Social.PostActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.Social.PostActions

  test "renders quote button only once" do
    html =
      render_component(&PostActions.post_actions/1,
        post_id: "https://example.com/posts/1",
        current_user: %{id: 123, username: "tester"},
        quote_count: 4,
        show_quote: true
      )

    assert length(Regex.scan(~r/hero-chat-bubble-bottom-center-text/, html)) == 1
  end
end
