defmodule ElektrineWeb.DiscussionsLive.PostRouter do
  @moduledoc """
  Routes handle_event calls for the discussion post detail view.
  """

  require Logger

  alias ElektrineWeb.DiscussionsLive.PostOperations.{
    ReplyOperations,
    VotingOperations,
    ModerationOperations,
    UIOperations
  }

  def route_event(event_name, params, socket) do
    case event_name do
      # Reply Operations
      "toggle_reply_form" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "create_reply" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "update_reply_content" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "show_nested_reply_form" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "cancel_nested_reply" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "create_nested_reply" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "update_nested_reply_content" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "load_more_replies" ->
        ReplyOperations.handle_event(event_name, params, socket)

      # Voting Operations
      "vote" ->
        VotingOperations.handle_event(event_name, params, socket)

      "vote_poll" ->
        VotingOperations.handle_event(event_name, params, socket)

      "like_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "react_to_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      # Moderation Operations
      "delete_post_admin" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "delete_discussion" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "delete_post_mod" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "pin_post" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "unpin_post" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "delete_reply" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "lock_thread" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "unlock_thread" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_ban_modal" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_ban" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "ban_user" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_warning_modal" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_warning" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "warn_user" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_timeout_modal" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_timeout" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "timeout_user" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_note_modal" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_note" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "add_moderator_note" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_user_mod_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "close_user_mod_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "unban_from_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "remove_timeout_from_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      # UI Operations
      "navigate_to_origin" ->
        UIOperations.handle_event(event_name, params, socket)

      "navigate_to_embedded_post" ->
        UIOperations.handle_event(event_name, params, socket)

      "stop_event" ->
        UIOperations.handle_event(event_name, params, socket)

      "copy_discussion_link" ->
        UIOperations.handle_event(event_name, params, socket)

      "copy_link" ->
        UIOperations.handle_event(event_name, params, socket)

      "report_discussion" ->
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

      _ ->
        Logger.warning("Unknown event in DiscussionsLive.Post: #{event_name}")
        {:noreply, socket}
    end
  end
end
