defmodule ElektrineWeb.DiscussionsLive.Router do
  @moduledoc """
  Routes handle_event calls to the appropriate operation module.
  This module acts as a dispatcher to keep the main LiveView clean.
  """

  alias ElektrineWeb.DiscussionsLive.Operations.{
    FlairOperations,
    MemberOperations,
    ModerationOperations,
    PostOperations,
    UiOperations,
    VotingOperations
  }

  @doc """
  Routes an event to the appropriate operation module based on the event name.
  Returns {:noreply, socket} tuple.
  """
  def route_event(event_name, params, socket) do
    case event_name do
      # Post Operations
      "toggle_new_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "select_post_type" ->
        PostOperations.handle_event(event_name, params, socket)

      "open_image_upload" ->
        PostOperations.handle_event(event_name, params, socket)

      "close_image_upload" ->
        PostOperations.handle_event(event_name, params, socket)

      "validate_discussion_upload" ->
        PostOperations.handle_event(event_name, params, socket)

      "upload_discussion_images" ->
        PostOperations.handle_event(event_name, params, socket)

      "clear_pending_images" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_link_url" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_post_form" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_post_title" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_post_content" ->
        PostOperations.handle_event(event_name, params, socket)

      "add_poll_option" ->
        PostOperations.handle_event(event_name, params, socket)

      "remove_poll_option" ->
        PostOperations.handle_event(event_name, params, socket)

      "create_discussion_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "view_discussion" ->
        PostOperations.handle_event(event_name, params, socket)

      "copy_discussion_link" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_discussion" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_discussion_admin" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_post_mod" ->
        PostOperations.handle_event(event_name, params, socket)

      "pin_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "unpin_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "set_pin_role" ->
        PostOperations.handle_event(event_name, params, socket)

      "lock_thread" ->
        PostOperations.handle_event(event_name, params, socket)

      "unlock_thread" ->
        PostOperations.handle_event(event_name, params, socket)

      "show_reply_form" ->
        PostOperations.handle_event(event_name, params, socket)

      "cancel_reply" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_reply_content" ->
        PostOperations.handle_event(event_name, params, socket)

      "create_reply" ->
        PostOperations.handle_event(event_name, params, socket)

      "share_to_timeline" ->
        PostOperations.handle_event(event_name, params, socket)

      # Moderation Operations
      "show_ban_modal" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_ban" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "ban_user" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "unban_user" ->
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

      "approve_post" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "reject_post" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "new_automod_rule" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "cancel_automod_rule" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "create_automod_rule" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "toggle_automod_rule" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "delete_automod_rule" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "show_user_mod_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "close_user_mod_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "unban_from_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      "remove_timeout_from_status" ->
        ModerationOperations.handle_event(event_name, params, socket)

      # Member Operations
      "join_community" ->
        MemberOperations.handle_event(event_name, params, socket)

      "leave_community" ->
        MemberOperations.handle_event(event_name, params, socket)

      "search_members" ->
        MemberOperations.handle_event(event_name, params, socket)

      "toggle_follow" ->
        MemberOperations.handle_event(event_name, params, socket)

      # Voting Operations
      "vote" ->
        VotingOperations.handle_event(event_name, params, socket)

      "show_voters" ->
        VotingOperations.handle_event(event_name, params, socket)

      "close_voters" ->
        VotingOperations.handle_event(event_name, params, socket)

      "switch_voters_tab" ->
        VotingOperations.handle_event(event_name, params, socket)

      "vote_poll" ->
        VotingOperations.handle_event(event_name, params, socket)

      # Flair Operations
      "new_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      "edit_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      "cancel_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      "create_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      "update_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      "delete_flair" ->
        FlairOperations.handle_event(event_name, params, socket)

      # UI Operations
      "switch_view" ->
        UiOperations.handle_event(event_name, params, socket)

      "filter_by_hashtag" ->
        UiOperations.handle_event(event_name, params, socket)

      "set_sort" ->
        UiOperations.handle_event(event_name, params, socket)

      "report_discussion" ->
        UiOperations.handle_event(event_name, params, socket)

      "close_report_modal" ->
        UiOperations.handle_event(event_name, params, socket)

      "navigate_to_origin" ->
        UiOperations.handle_event(event_name, params, socket)

      "copy_link" ->
        UiOperations.handle_event(event_name, params, socket)

      "view_original_context" ->
        UiOperations.handle_event(event_name, params, socket)

      "navigate_to_post" ->
        UiOperations.handle_event(event_name, params, socket)

      "navigate_to_embedded_post" ->
        UiOperations.handle_event(event_name, params, socket)

      "stop_event" ->
        UiOperations.handle_event(event_name, params, socket)

      "stop_propagation" ->
        UiOperations.handle_event(event_name, params, socket)

      "noop" ->
        UiOperations.handle_event(event_name, params, socket)

      "close_dropdown" ->
        UiOperations.handle_event(event_name, params, socket)

      "update" ->
        UiOperations.handle_event(event_name, params, socket)

      "open_image_modal" ->
        UiOperations.handle_event(event_name, params, socket)

      "close_image_modal" ->
        UiOperations.handle_event(event_name, params, socket)

      "next_image" ->
        UiOperations.handle_event(event_name, params, socket)

      "prev_image" ->
        UiOperations.handle_event(event_name, params, socket)

      "next_media_post" ->
        UiOperations.handle_event(event_name, params, socket)

      "prev_media_post" ->
        UiOperations.handle_event(event_name, params, socket)

      # Unknown event - return error
      _ ->
        require Logger
        Logger.warning("Unknown event in DiscussionsLive.Community: #{event_name}")
        {:noreply, socket}
    end
  end
end
