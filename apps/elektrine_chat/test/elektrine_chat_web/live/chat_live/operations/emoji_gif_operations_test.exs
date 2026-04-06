defmodule ElektrineChatWeb.ChatLive.Operations.EmojiGifOperationsTest do
  use ExUnit.Case, async: true

  alias ElektrineChatWeb.ChatLive.Operations.EmojiGifOperations
  alias Phoenix.LiveView.Socket

  test "emoji_search accepts keyup payloads with value" do
    socket = %Socket{
      assigns: %{__changed__: %{}, search: %{emoji_query: "", emoji_tab: "Smileys"}}
    }

    assert {:noreply, updated_socket} =
             EmojiGifOperations.handle_event(
               "emoji_search",
               %{"key" => "y", "value" => "cry"},
               socket
             )

    assert updated_socket.assigns.search.emoji_query == "cry"
  end
end
