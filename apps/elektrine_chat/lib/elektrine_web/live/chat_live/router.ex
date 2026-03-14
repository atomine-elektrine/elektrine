defmodule ElektrineWeb.ChatLive.Router do
  @moduledoc """
  Routes handle_event calls to the appropriate operation module.
  This module acts as a dispatcher to keep the main LiveView clean.
  """

  require Logger

  alias ElektrineWeb.ChatLive.Operations.{
    CallOperations,
    ContextMenuOperations,
    ConversationOperations,
    DirectMessageOperations,
    EmojiGifOperations,
    GroupChannelOperations,
    MemberOperations,
    MessageOperations,
    UIOperations
  }

  @event_handlers %{
    "send_message" => MessageOperations,
    "update_message" => MessageOperations,
    "stop_typing" => MessageOperations,
    "handle_keydown" => MessageOperations,
    "validate_upload" => MessageOperations,
    "cancel_upload" => MessageOperations,
    "load_older_messages" => MessageOperations,
    "load_newer_messages" => MessageOperations,
    "scroll_to_newest" => MessageOperations,
    "scroll_to_message" => MessageOperations,
    "react_to_message" => MessageOperations,
    "cancel_reply" => MessageOperations,
    "reply_to_message" => MessageOperations,
    "copy_message" => MessageOperations,
    "delete_message" => MessageOperations,
    "delete_message_admin" => MessageOperations,
    "search_messages" => MessageOperations,
    "pin_message" => MessageOperations,
    "unpin_message" => MessageOperations,
    "send_voice_message" => MessageOperations,
    "voice_recording_error" => MessageOperations,
    "select_conversation" => ConversationOperations,
    "search_conversations" => ConversationOperations,
    "clear_selection" => ConversationOperations,
    "pin_conversation" => ConversationOperations,
    "unpin_conversation" => ConversationOperations,
    "mark_as_read" => ConversationOperations,
    "clear_history" => ConversationOperations,
    "show_settings" => ConversationOperations,
    "hide_settings" => ConversationOperations,
    "show_edit_conversation" => ConversationOperations,
    "hide_edit_conversation" => ConversationOperations,
    "update_conversation" => ConversationOperations,
    "delete_conversation" => ConversationOperations,
    "leave_conversation" => ConversationOperations,
    "view_profile" => ConversationOperations,
    "share_conversation" => ConversationOperations,
    "show_conversation_info" => ConversationOperations,
    "toggle_new_chat" => GroupChannelOperations,
    "show_create_group" => GroupChannelOperations,
    "show_create_server" => GroupChannelOperations,
    "hide_create_server" => GroupChannelOperations,
    "show_create_channel" => GroupChannelOperations,
    "create_group" => GroupChannelOperations,
    "create_server" => GroupChannelOperations,
    "create_channel" => GroupChannelOperations,
    "cancel_create" => GroupChannelOperations,
    "toggle_user_selection" => GroupChannelOperations,
    "show_browse_modal" => GroupChannelOperations,
    "hide_browse_modal" => GroupChannelOperations,
    "browse_tab" => GroupChannelOperations,
    "browse_search" => GroupChannelOperations,
    "join_conversation" => GroupChannelOperations,
    "join_group" => GroupChannelOperations,
    "join_channel" => GroupChannelOperations,
    "join_server" => GroupChannelOperations,
    "filter_server" => GroupChannelOperations,
    "select_server" => GroupChannelOperations,
    "clear_server_scope" => GroupChannelOperations,
    "show_add_members" => MemberOperations,
    "hide_add_members" => MemberOperations,
    "add_member_to_conversation" => MemberOperations,
    "kick_member" => MemberOperations,
    "promote_member" => MemberOperations,
    "demote_member" => MemberOperations,
    "timeout_user" => MemberOperations,
    "remove_timeout_user" => MemberOperations,
    "kick_user" => MemberOperations,
    "show_member_management" => MemberOperations,
    "hide_member_management" => MemberOperations,
    "show_moderation_log" => MemberOperations,
    "hide_moderation_log" => MemberOperations,
    "start_dm" => DirectMessageOperations,
    "search_users" => DirectMessageOperations,
    "block_user" => DirectMessageOperations,
    "unblock_user" => DirectMessageOperations,
    "show_user_profile" => DirectMessageOperations,
    "hide_profile_modal" => DirectMessageOperations,
    "initiate_call" => CallOperations,
    "answer_call" => CallOperations,
    "reject_call" => CallOperations,
    "end_call" => CallOperations,
    "toggle_audio" => CallOperations,
    "toggle_video" => CallOperations,
    "audio_toggled" => CallOperations,
    "video_toggled" => CallOperations,
    "call_error" => CallOperations,
    "call_started" => CallOperations,
    "remote_stream_ready" => CallOperations,
    "call_answered" => CallOperations,
    "call_connected" => CallOperations,
    "call_ended" => CallOperations,
    "call_ended_by_user" => CallOperations,
    "call_rejected" => CallOperations,
    "close_dropdown" => UIOperations,
    "toggle_mobile_search" => UIOperations,
    "stop_event" => UIOperations,
    "navigate_to_origin" => UIOperations,
    "navigate_to_embedded_post" => UIOperations,
    "show_message_search" => UIOperations,
    "hide_message_search" => UIOperations,
    "ignore" => UIOperations,
    "view_original_context" => UIOperations,
    "show_report_modal" => UIOperations,
    "close_report_modal" => UIOperations,
    "open_image_modal" => UIOperations,
    "close_image_modal" => UIOperations,
    "next_image" => UIOperations,
    "prev_image" => UIOperations,
    "next_media_post" => UIOperations,
    "prev_media_post" => UIOperations,
    "show_context_menu" => ContextMenuOperations,
    "hide_context_menu" => ContextMenuOperations,
    "show_message_context_menu" => ContextMenuOperations,
    "hide_message_context_menu" => ContextMenuOperations,
    "toggle_emoji_picker" => EmojiGifOperations,
    "toggle_gif_picker" => EmojiGifOperations,
    "insert_emoji" => EmojiGifOperations,
    "search_gifs" => EmojiGifOperations,
    "insert_gif" => EmojiGifOperations,
    "emoji_search" => EmojiGifOperations,
    "emoji_tab" => EmojiGifOperations
  }

  @doc false
  def handler_for(event_name), do: Map.get(@event_handlers, event_name)

  @doc false
  def event_handlers, do: @event_handlers

  @doc """
  Routes an event to the appropriate operation module based on the event name.
  Returns {:noreply, socket} tuple.
  """
  def route_event(event_name, params, socket) do
    case handler_for(event_name) do
      nil ->
        Logger.warning("Unknown event in ChatLive.Index: #{event_name}")
        {:noreply, socket}

      handler_module ->
        handler_module.handle_event(event_name, params, socket)
    end
  end
end
