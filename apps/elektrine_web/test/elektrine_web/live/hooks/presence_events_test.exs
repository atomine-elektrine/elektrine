defmodule ElektrineWeb.Live.Hooks.PresenceEventsTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.Live.Hooks.PresenceEvents

  test "auto_away_timeout initializes missing user_statuses assign" do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        current_user: %{id: 123, status: "online"}
      }
    }

    assert {:noreply, updated_socket} =
             PresenceEvents.handle_presence_event("auto_away_timeout", %{}, socket)

    assert updated_socket.assigns.is_auto_away == true
    assert %{"123" => %{status: "away"}} = updated_socket.assigns.user_statuses
  end

  test "user_activity clears auto-away when user_statuses is missing" do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        current_user: %{id: 123, status: "online"},
        is_auto_away: true
      }
    }

    assert {:noreply, updated_socket} =
             PresenceEvents.handle_presence_event(
               "user_activity",
               %{"clear_away" => true},
               socket
             )

    assert updated_socket.assigns.is_auto_away == false
    assert %{"123" => %{status: "online"}} = updated_socket.assigns.user_statuses
  end
end
