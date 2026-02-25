defmodule ElektrineWeb.RemoteUserLive.ShowTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.RemoteUserLive.Show

  test "handles record_dwell_times for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dwell_times",
               %{
                 "views" => [
                   %{
                     "post_id" => "200202",
                     "dwell_time_ms" => 2452,
                     "scroll_depth" => 1,
                     "expanded" => false,
                     "source" => "remote_profile"
                   }
                 ]
               },
               socket
             )

    assert {:noreply, ^socket} =
             Show.handle_event("record_dwell_times", %{"views" => "invalid"}, socket)
  end

  test "handles record_dwell_time for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dwell_time",
               %{
                 "post_id" => "200202",
                 "dwell_time_ms" => 2452,
                 "scroll_depth" => 1,
                 "expanded" => false,
                 "source" => "remote_profile"
               },
               socket
             )
  end

  test "handles record_dismissal for anonymous users" do
    socket = %{assigns: %{current_user: nil}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "record_dismissal",
               %{
                 "post_id" => "200202",
                 "type" => "scrolled_past",
                 "dwell_time_ms" => 100
               },
               socket
             )
  end

  test "navigates embedded post URLs" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "/timeline/post/42"},
               socket
             )

    assert inspect(updated_socket.redirected) =~ "/timeline/post/42"
  end
end
