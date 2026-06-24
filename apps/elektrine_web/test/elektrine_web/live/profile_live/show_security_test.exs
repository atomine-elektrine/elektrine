defmodule ElektrineWeb.ProfileLive.ShowSecurityTest do
  use ElektrineWeb.ConnCase, async: false

  alias ElektrineWeb.ProfileLive.Show

  test "ignores malformed image modal payloads" do
    socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

    assert {:noreply, socket} =
             Show.handle_event(
               "open_image_modal",
               %{
                 "images" => "not-json",
                 "index" => "12abc",
                 "post_id" => "34abc"
               },
               socket
             )

    assert socket.assigns.flash["error"] == "Image not found"
  end
end
