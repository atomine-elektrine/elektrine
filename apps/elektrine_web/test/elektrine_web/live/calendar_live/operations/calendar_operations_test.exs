defmodule ElektrineWeb.CalendarLive.Operations.CalendarOperationsTest do
  use Elektrine.DataCase, async: true

  alias ElektrineWeb.CalendarLive.Operations.CalendarOperations

  test "calendar operations reject malformed ids" do
    socket = calendar_socket()

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event(
               "toggle_calendar",
               %{"id" => "12abc"},
               socket
             )

    assert socket.assigns.visible_calendars == MapSet.new([1])

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event("edit_event", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Event not found"

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event("view_event", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Event not found"

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event("delete_event", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Could not delete event"

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event("edit_calendar", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Calendar not found"

    assert {:noreply, socket} =
             CalendarOperations.handle_calendar_event(
               "delete_calendar",
               %{"id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Could not delete calendar"
  end

  defp calendar_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        visible_calendars: MapSet.new([1]),
        events: [],
        calendars: []
      }
    }
  end
end
