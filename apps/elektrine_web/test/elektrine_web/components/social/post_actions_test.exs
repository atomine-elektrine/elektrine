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

  test "reserves count space while interaction counts are loading and unknown" do
    html =
      render_component(&PostActions.post_actions/1,
        post_id: "https://example.com/posts/1",
        current_user: %{id: 123, username: "tester"},
        like_count: nil,
        comment_count: nil,
        boost_count: nil,
        quote_count: nil,
        counts_loading: true
      )

    assert length(Regex.scan(~r/aria-busy="true"/, html)) == 4
    assert length(:binary.matches(html, "--")) == 4
    refute html =~ ~s(data-count="0")
  end

  test "keeps known interaction counts visible while counts refresh" do
    html =
      render_component(&PostActions.post_actions/1,
        post_id: "https://example.com/posts/1",
        current_user: %{id: 123, username: "tester"},
        like_count: 7,
        comment_count: 3,
        boost_count: 2,
        counts_loading: true
      )

    assert html =~ ~s(data-count="7")
    assert html =~ ~s(data-count="3")
    assert html =~ ~s(data-count="2")
    refute html =~ "text-transparent select-none"
  end

  test "renders reaction dropdown directly before save button when enabled" do
    html =
      render_component(&PostActions.post_actions/1,
        post_id: 123,
        value_name: "message_id",
        dom_id_prefix: "post-actions-123",
        current_user: %{id: 1, username: "tester"},
        show_react: true,
        show_save: true,
        is_saved: false
      )

    assert html =~
             ~s(<details class="dropdown dropdown-end dropdown-top timeline-reaction-dropdown)

    assert html =~ ~s(dropdown-content bottom-full right-0)
    assert html =~ ~s(title="React")
    assert html =~ ~s(phx-click="react_to_post")
    assert html =~ ~s(phx-value-emoji="👍")
    assert html =~ ~s(phx-value-emoji="🔥")
    assert html =~ ~s(id="post-actions-123-save")

    reaction_index = :binary.match(html, ~s(title="React")) |> elem(0)
    save_index = :binary.match(html, ~s(id="post-actions-123-save")) |> elem(0)

    assert reaction_index < save_index
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

  test "upvotes show the optimistic like-style loading animation" do
    inactive_html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: %{id: 1},
        score: 2,
        is_upvoted: false
      )

    active_html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: %{id: 1},
        score: 3,
        is_upvoted: true
      )

    downvoted_html =
      render_component(&PostActions.vote_buttons/1,
        post_id: 123,
        current_user: %{id: 1},
        score: -1,
        is_downvoted: true
      )

    inactive_button = upvote_button(inactive_html)
    active_button = upvote_button(active_html)

    assert inactive_button =~ "phx-click-loading:scale-95"
    assert inactive_button =~ "phx-click-loading:opacity-80"
    assert inactive_button =~ ~s(class="inline-flex phx-click-loading:hidden")
    assert inactive_button =~ "hero-arrow-up-solid"

    assert active_button =~ ~s(class="hidden phx-click-loading:inline-flex")
    assert active_button =~ "phx-click-loading:text-base-content/70"
    assert active_button =~ "hero-arrow-up-solid"
    assert active_button =~ "hero-arrow-up"

    assert pending_score(inactive_html) == "3"
    assert pending_score(active_html) == "2"
    assert pending_score(downvoted_html) == "1"
  end

  defp upvote_button(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(button[phx-value-type="up"]))
    |> Floki.raw_html()
  end

  defp pending_score(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(".vote-score-pending")
    |> Floki.text()
    |> String.trim()
  end
end
