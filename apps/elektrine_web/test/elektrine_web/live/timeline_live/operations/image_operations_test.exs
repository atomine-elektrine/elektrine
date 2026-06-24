defmodule ElektrineSocialWeb.TimelineLive.Operations.ImageOperationsTest do
  use ExUnit.Case, async: true

  alias ElektrineSocialWeb.TimelineLive.Operations.ImageOperations

  test "open_image_modal ignores malformed params" do
    socket = timeline_socket()

    assert {:noreply, ^socket} =
             ImageOperations.handle_event(
               "open_image_modal",
               %{"images" => "not-json", "index" => "0", "post_id" => "1"},
               socket
             )

    assert {:noreply, ^socket} =
             ImageOperations.handle_event(
               "open_image_modal",
               %{"images" => Jason.encode!([]), "index" => "0", "post_id" => "1"},
               socket
             )

    assert {:noreply, ^socket} =
             ImageOperations.handle_event(
               "open_image_modal",
               %{
                 "images" => Jason.encode!(["https://example.com/a.png"]),
                 "index" => "0",
                 "post_id" => "bad"
               },
               socket
             )
  end

  test "open_image_modal uses a safe fallback for malformed indexes" do
    socket = timeline_socket()
    images = ["https://example.com/a.png"]

    assert {:noreply, updated_socket} =
             ImageOperations.handle_event(
               "open_image_modal",
               %{"images" => Jason.encode!(images), "index" => "not-an-int", "post_id" => "1"},
               socket
             )

    assert updated_socket.assigns.show_image_modal
    assert updated_socket.assigns.modal_image_url == hd(images)
    assert updated_socket.assigns.modal_images == images
    assert updated_socket.assigns.modal_image_index == 0
    assert updated_socket.assigns.modal_post.id == 1
  end

  defp timeline_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        timeline_posts: [%{id: 1, media_urls: ["https://example.com/a.png"]}]
      }
    }
  end
end
