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

  test "hides zero vote score when there is no active vote" do
    html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: nil,
        score: 0
      )

    refute html =~ ~s(aria-label="Score: 0")
  end

  test "shows non-zero or active vote score" do
    non_zero_html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: nil,
        score: 2
      )

    active_vote_html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: %{id: 1},
        score: 0,
        is_upvoted: true
      )

    assert non_zero_html =~ ~s(aria-label="Score: 2")
    assert active_vote_html =~ ~s(aria-label="Score: 0")
  end
end
