defmodule ElektrineWeb.TimelineLive.Operations.ReplyOperationsTest do
  use ElektrineWeb.ConnCase, async: true

  alias ElektrineSocialWeb.TimelineLive.Operations.ReplyOperations

  test "view original context rejects malformed message ids" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    assert {:noreply, socket} =
             ReplyOperations.handle_event(
               "view_original_context",
               %{"message_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Original content not found"
  end
end
