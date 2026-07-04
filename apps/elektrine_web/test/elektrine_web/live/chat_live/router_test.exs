defmodule ArblargWeb.ChatLive.RouterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ArblargWeb.ChatLive.Router

  alias ArblargWeb.ChatLive.Operations.{
    CallOperations,
    ContextMenuOperations,
    ConversationOperations,
    DirectMessageOperations,
    EmojiGifOperations,
    GroupChannelOperations,
    MemberOperations,
    MessageOperations,
    ThreadOperations,
    UIOperations,
    VoiceChannelOperations
  }

  test "handler_for/1 resolves representative events for each operation module" do
    assert Router.handler_for("send_message") == MessageOperations
    assert Router.handler_for("select_conversation") == ConversationOperations
    assert Router.handler_for("create_group") == GroupChannelOperations
    assert Router.handler_for("show_add_members") == MemberOperations
    assert Router.handler_for("start_dm") == DirectMessageOperations
    assert Router.handler_for("initiate_call") == CallOperations
    assert Router.handler_for("open_image_modal") == UIOperations
    assert Router.handler_for("show_context_menu") == ContextMenuOperations
    assert Router.handler_for("toggle_emoji_picker") == EmojiGifOperations
    assert Router.handler_for("nonexistent-event") == nil
  end

  test "event_handlers/0 contains the full chat event surface" do
    handlers = Router.event_handlers()

    assert map_size(handlers) == 149
    assert Map.fetch!(handlers, "send_message") == MessageOperations
    assert Map.fetch!(handlers, "create_thread") == ThreadOperations
    assert Map.fetch!(handlers, "join_voice_channel") == VoiceChannelOperations
    # remote-join review events were previously unrouted (dead buttons); now wired
    assert Map.fetch!(handlers, "approve_remote_join_request") == MemberOperations
    assert Map.fetch!(handlers, "decline_remote_join_request") == MemberOperations
    assert Map.fetch!(handlers, "emoji_tab") == EmojiGifOperations
  end

  test "route_event/3 logs and no-ops on unknown events" do
    socket = %Phoenix.LiveView.Socket{}

    log =
      capture_log(fn ->
        assert {:noreply, ^socket} = Router.route_event("totally_unknown_event", %{}, socket)
      end)

    assert log =~ "Unknown event in ChatLive.Index: totally_unknown_event"
  end
end
