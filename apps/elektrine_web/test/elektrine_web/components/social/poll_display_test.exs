defmodule ElektrineWeb.Components.Social.PollDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Messaging.OptionalSocialSchemas.{Poll, PollOption}
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
end
