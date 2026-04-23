defmodule ElektrineWeb.Components.Social.PollDisplayTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Social.{Poll, PollOption}
  alias ElektrineWeb.Components.Social.PollDisplay

  test "renders local poll cards for optional social poll structs" do
    poll = %Poll{
      id: 62,
      question: "#Bread ?",
      closes_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      total_votes: 0,
      options: [
        %PollOption{id: 114, option_text: "Better now than it was", vote_count: 0, position: 0},
        %PollOption{id: 115, option_text: "Always has been", vote_count: 0, position: 1}
      ]
    }

    html =
      render_component(&PollDisplay.poll_card/1,
        poll: poll,
        message: %{federated: false},
        current_user: nil,
        user_votes: [],
        interactive: false
      )

    assert html =~ "#Bread ?"
    assert html =~ "Better now than it was"
    assert html =~ "Always has been"
  end

  test "federated local poll cards use remote vote event" do
    poll = %Poll{
      id: 62,
      question: "Remote poll?",
      closes_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      total_votes: 0,
      options: [
        %PollOption{id: 114, option_text: "Yes", vote_count: 0, position: 0}
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
          remote_actor: nil
        },
        current_user: %{id: 1},
        user_votes: [],
        interactive: true
      )

    assert html =~ ~s(phx-click="vote_poll")
    assert html =~ ~s(phx-value-option_name="Yes")
    assert html =~ ~s(phx-value-message_id="123")
  end
end
