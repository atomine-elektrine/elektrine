defmodule ElektrineSocialWeb.Components.Social.PollDisplayTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Social.{Poll, PollOption}
  alias ElektrineSocialWeb.Components.Social.PollDisplay

  test "shows optimistic feedback for pending remote poll votes" do
    poll = %Poll{
      id: 62,
      question: "Remote poll?",
      closes_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      total_votes: 10,
      options: [
        %PollOption{id: 114, option_text: "Yes", vote_count: 4, position: 0},
        %PollOption{id: 115, option_text: "No", vote_count: 6, position: 1}
      ]
    }

    html =
      render_component(&PollDisplay.poll_card/1,
        poll: poll,
        message: %{
          id: 123,
          federated: true,
          activitypub_id: "https://remote.example/polls/123",
          activitypub_url: "https://remote.example/polls/123",
          remote_actor: %{domain: "remote.example"}
        },
        current_user: %{id: 1},
        user_votes: [],
        optimistic_vote: %{option_id: 114, option_name: "Yes", domain: "remote.example"},
        interactive: true
      )

    assert html =~ "Vote registered. Syncing with the original instance."
    assert html =~ ~s(hero-check-circle)
    assert html =~ "11 votes"
    assert html =~ ">(5)</span>"
  end

  test "keeps local poll options clickable after a user has voted" do
    poll = %Poll{
      id: 63,
      question: "Choose one",
      closes_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      total_votes: 1,
      options: [
        %PollOption{id: 116, option_text: "Yes", vote_count: 1, position: 0},
        %PollOption{id: 117, option_text: "No", vote_count: 0, position: 1}
      ]
    }

    html =
      render_component(&PollDisplay.poll_card/1,
        poll: poll,
        message: %{id: 124, federated: false},
        current_user: %{id: 1},
        user_votes: [116],
        interactive: true
      )

    assert html =~ ~s(phx-click="vote_poll")
    assert html =~ ~s(phx-value-option_id="116")
    assert html =~ ~s(phx-value-option_id="117")
  end
end
