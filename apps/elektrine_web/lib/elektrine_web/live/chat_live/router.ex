defmodule ElektrineWeb.ChatLive.Router do
  @moduledoc """
  Routes handle_event calls to the appropriate operation module.
  This module acts as a dispatcher to keep the main LiveView clean.
  """

  alias ElektrineWeb.ChatLive.Operations.{
    MessageOperations,
    ConversationOperations,
    GroupChannelOperations,
    MemberOperations,
    DirectMessageOperations,
    CallOperations,
    UIOperations,
    ContextMenuOperations,
    EmojiGifOperations
  }

  @doc """
  Routes an event to the appropriate operation module based on the event name.
  Returns {:noreply, socket} tuple.
  """
  def route_event(event_name, params, socket) do
    case event_name do
      # Message Operations
      "send_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "update_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "stop_typing" ->
        MessageOperations.handle_event(event_name, params, socket)

      "handle_keydown" ->
        MessageOperations.handle_event(event_name, params, socket)

      "validate_upload" ->
        MessageOperations.handle_event(event_name, params, socket)

      "cancel_upload" ->
        MessageOperations.handle_event(event_name, params, socket)

      "load_older_messages" ->
        MessageOperations.handle_event(event_name, params, socket)

      "load_newer_messages" ->
        MessageOperations.handle_event(event_name, params, socket)

      "scroll_to_newest" ->
        MessageOperations.handle_event(event_name, params, socket)

      "scroll_to_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "react_to_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "cancel_reply" ->
        MessageOperations.handle_event(event_name, params, socket)

      "reply_to_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "copy_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "delete_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "delete_message_admin" ->
        MessageOperations.handle_event(event_name, params, socket)

      "search_messages" ->
        MessageOperations.handle_event(event_name, params, socket)

      "pin_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "unpin_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "send_voice_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      "voice_recording_error" ->
        MessageOperations.handle_event(event_name, params, socket)

      # Conversation Operations
      "select_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "search_conversations" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "clear_selection" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "pin_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "unpin_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "mark_as_read" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "clear_history" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "show_settings" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "hide_settings" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "show_edit_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "hide_edit_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "update_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "delete_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "leave_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "view_profile" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "share_conversation" ->
        ConversationOperations.handle_event(event_name, params, socket)

      "show_conversation_info" ->
        ConversationOperations.handle_event(event_name, params, socket)

      # Group/Channel Operations
      "toggle_new_chat" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "show_create_group" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "show_create_channel" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "create_group" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "create_channel" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "cancel_create" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "toggle_user_selection" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "show_browse_modal" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "hide_browse_modal" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "browse_tab" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "browse_search" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "join_conversation" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "join_group" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      "join_channel" ->
        GroupChannelOperations.handle_event(event_name, params, socket)

      # Member Operations
      "show_add_members" ->
        MemberOperations.handle_event(event_name, params, socket)

      "hide_add_members" ->
        MemberOperations.handle_event(event_name, params, socket)

      "add_member_to_conversation" ->
        MemberOperations.handle_event(event_name, params, socket)

      "kick_member" ->
        MemberOperations.handle_event(event_name, params, socket)

      "promote_member" ->
        MemberOperations.handle_event(event_name, params, socket)

      "demote_member" ->
        MemberOperations.handle_event(event_name, params, socket)

      "timeout_user" ->
        MemberOperations.handle_event(event_name, params, socket)

      "remove_timeout_user" ->
        MemberOperations.handle_event(event_name, params, socket)

      "kick_user" ->
        MemberOperations.handle_event(event_name, params, socket)

      "show_member_management" ->
        MemberOperations.handle_event(event_name, params, socket)

      "hide_member_management" ->
        MemberOperations.handle_event(event_name, params, socket)

      "show_moderation_log" ->
        MemberOperations.handle_event(event_name, params, socket)

      "hide_moderation_log" ->
        MemberOperations.handle_event(event_name, params, socket)

      # Direct Message Operations
      "start_dm" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      "search_users" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      "block_user" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      "unblock_user" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      "show_user_profile" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      "hide_profile_modal" ->
        DirectMessageOperations.handle_event(event_name, params, socket)

      # Call Operations
      "initiate_call" ->
        CallOperations.handle_event(event_name, params, socket)

      "answer_call" ->
        CallOperations.handle_event(event_name, params, socket)

      "reject_call" ->
        CallOperations.handle_event(event_name, params, socket)

      "end_call" ->
        CallOperations.handle_event(event_name, params, socket)

      "toggle_audio" ->
        CallOperations.handle_event(event_name, params, socket)

      "toggle_video" ->
        CallOperations.handle_event(event_name, params, socket)

      "audio_toggled" ->
        CallOperations.handle_event(event_name, params, socket)

      "video_toggled" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_error" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_started" ->
        CallOperations.handle_event(event_name, params, socket)

      "remote_stream_ready" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_answered" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_connected" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_ended" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_ended_by_user" ->
        CallOperations.handle_event(event_name, params, socket)

      "call_rejected" ->
        CallOperations.handle_event(event_name, params, socket)

      # UI Operations
      "close_dropdown" ->
        UIOperations.handle_event(event_name, params, socket)

      "toggle_mobile_search" ->
        UIOperations.handle_event(event_name, params, socket)

      "stop_event" ->
        UIOperations.handle_event(event_name, params, socket)

      "navigate_to_origin" ->
        UIOperations.handle_event(event_name, params, socket)

      "navigate_to_embedded_post" ->
        UIOperations.handle_event(event_name, params, socket)

      "show_message_search" ->
        UIOperations.handle_event(event_name, params, socket)

      "hide_message_search" ->
        UIOperations.handle_event(event_name, params, socket)

      "ignore" ->
        UIOperations.handle_event(event_name, params, socket)

      "view_original_context" ->
        UIOperations.handle_event(event_name, params, socket)

      "show_report_modal" ->
        UIOperations.handle_event(event_name, params, socket)

      "close_report_modal" ->
        UIOperations.handle_event(event_name, params, socket)

      "open_image_modal" ->
        UIOperations.handle_event(event_name, params, socket)

      "close_image_modal" ->
        UIOperations.handle_event(event_name, params, socket)

      "next_image" ->
        UIOperations.handle_event(event_name, params, socket)

      "prev_image" ->
        UIOperations.handle_event(event_name, params, socket)

      "next_media_post" ->
        UIOperations.handle_event(event_name, params, socket)

      "prev_media_post" ->
        UIOperations.handle_event(event_name, params, socket)

      # Context Menu Operations
      "show_context_menu" ->
        ContextMenuOperations.handle_event(event_name, params, socket)

      "hide_context_menu" ->
        ContextMenuOperations.handle_event(event_name, params, socket)

      "show_message_context_menu" ->
        ContextMenuOperations.handle_event(event_name, params, socket)

      "hide_message_context_menu" ->
        ContextMenuOperations.handle_event(event_name, params, socket)

      # Emoji/GIF Operations
      "toggle_emoji_picker" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "toggle_gif_picker" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "insert_emoji" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "search_gifs" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "insert_gif" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "emoji_search" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      "emoji_tab" ->
        EmojiGifOperations.handle_event(event_name, params, socket)

      # Unknown event - return error
      _ ->
        require Logger
        Logger.warning("Unknown event in ChatLive.Index: #{event_name}")
        {:noreply, socket}
    end
  end
end
