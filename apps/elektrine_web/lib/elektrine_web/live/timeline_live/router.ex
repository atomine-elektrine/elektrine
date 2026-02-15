defmodule ElektrineWeb.TimelineLive.Router do
  @moduledoc """
  Routes handle_event calls to the appropriate operation module.
  This module acts as a dispatcher to keep the main LiveView clean.
  """

  alias ElektrineWeb.TimelineLive.Operations.{
    PostOperations,
    VotingOperations,
    ImageOperations,
    NavigationOperations,
    SocialOperations,
    ReplyOperations,
    UIOperations,
    TrackingOperations
  }

  @doc """
  Routes an event to the appropriate operation module based on the event name.
  Returns {:noreply, socket} tuple.
  """
  def route_event(event_name, params, socket) do
    case event_name do
      # Navigation Operations
      "navigate_to_post" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_gallery_post" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_embedded_post" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "open_external_link" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "open_external_post" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_origin" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_profile" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_remote_profile" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "navigate_to_remote_post" ->
        NavigationOperations.handle_event(event_name, params, socket)

      # Post Operations
      "toggle_post_composer" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_post_title" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_visibility" ->
        PostOperations.handle_event(event_name, params, socket)

      "toggle_content_warning" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_content_warning" ->
        PostOperations.handle_event(event_name, params, socket)

      "update_post_content" ->
        PostOperations.handle_event(event_name, params, socket)

      "autosave_draft" ->
        PostOperations.handle_event(event_name, params, socket)

      "load_queued_posts" ->
        PostOperations.handle_event(event_name, params, socket)

      "create_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_post_admin" ->
        PostOperations.handle_event(event_name, params, socket)

      "view_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "copy_post_link" ->
        PostOperations.handle_event(event_name, params, socket)

      "report_post" ->
        PostOperations.handle_event(event_name, params, socket)

      "load_more_posts" ->
        PostOperations.handle_event(event_name, params, socket)

      "load-more" ->
        PostOperations.handle_event(event_name, params, socket)

      "filter_timeline" ->
        PostOperations.handle_event(event_name, params, socket)

      "toggle_filter_dropdown" ->
        PostOperations.handle_event(event_name, params, socket)

      "close_filter_dropdown" ->
        PostOperations.handle_event(event_name, params, socket)

      "set_filter" ->
        PostOperations.handle_event(event_name, params, socket)

      "set_software_filter" ->
        PostOperations.handle_event(event_name, params, socket)

      # Draft Operations
      "save_draft" ->
        PostOperations.handle_event(event_name, params, socket)

      "edit_draft" ->
        PostOperations.handle_event(event_name, params, socket)

      "publish_draft" ->
        PostOperations.handle_event(event_name, params, socket)

      "delete_draft" ->
        PostOperations.handle_event(event_name, params, socket)

      "show_drafts" ->
        PostOperations.handle_event(event_name, params, socket)

      "hide_drafts" ->
        PostOperations.handle_event(event_name, params, socket)

      # Image Operations
      "cancel_upload" ->
        ImageOperations.handle_event(event_name, params, socket)

      "open_image_upload" ->
        ImageOperations.handle_event(event_name, params, socket)

      "close_image_upload" ->
        ImageOperations.handle_event(event_name, params, socket)

      "clear_pending_images" ->
        ImageOperations.handle_event(event_name, params, socket)

      "open_image_modal" ->
        ImageOperations.handle_event(event_name, params, socket)

      "close_image_modal" ->
        ImageOperations.handle_event(event_name, params, socket)

      "next_image" ->
        ImageOperations.handle_event(event_name, params, socket)

      "prev_image" ->
        ImageOperations.handle_event(event_name, params, socket)

      "next_media_post" ->
        ImageOperations.handle_event(event_name, params, socket)

      "prev_media_post" ->
        ImageOperations.handle_event(event_name, params, socket)

      "validate_timeline_upload" ->
        ImageOperations.handle_event(event_name, params, socket)

      "upload_timeline_images" ->
        ImageOperations.handle_event(event_name, params, socket)

      # Voting Operations
      "like_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "unlike_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "downvote_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "undownvote_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "boost_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "unboost_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "vote_poll" ->
        VotingOperations.handle_event(event_name, params, socket)

      "react_to_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "toggle_modal_like" ->
        VotingOperations.handle_event(event_name, params, socket)

      "save_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "unsave_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "save_rss_item" ->
        VotingOperations.handle_event(event_name, params, socket)

      "unsave_rss_item" ->
        VotingOperations.handle_event(event_name, params, socket)

      "quote_post" ->
        VotingOperations.handle_event(event_name, params, socket)

      "close_quote_modal" ->
        VotingOperations.handle_event(event_name, params, socket)

      "update_quote_content" ->
        VotingOperations.handle_event(event_name, params, socket)

      "submit_quote" ->
        VotingOperations.handle_event(event_name, params, socket)

      # Social/Follow Operations
      "follow_suggested_user" ->
        SocialOperations.handle_event(event_name, params, socket)

      "refresh_suggestions" ->
        SocialOperations.handle_event(event_name, params, socket)

      "toggle_follow" ->
        SocialOperations.handle_event(event_name, params, socket)

      "preview_remote_user" ->
        SocialOperations.handle_event(event_name, params, socket)

      "follow_remote_user" ->
        SocialOperations.handle_event(event_name, params, socket)

      "toggle_follow_remote" ->
        SocialOperations.handle_event(event_name, params, socket)

      "discuss_privately" ->
        SocialOperations.handle_event(event_name, params, socket)

      # Reply Operations
      "show_reply_form" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "cancel_reply" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "show_reply_to_reply_form" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "create_timeline_reply" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "update_reply_content" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "view_original_context" ->
        ReplyOperations.handle_event(event_name, params, socket)

      "load_remote_replies" ->
        ReplyOperations.handle_event(event_name, params, socket)

      # UI Operations
      "stop_event" ->
        UIOperations.handle_event(event_name, params, socket)

      "close_dropdown" ->
        UIOperations.handle_event(event_name, params, socket)

      "close_report_modal" ->
        UIOperations.handle_event(event_name, params, socket)

      "stop_propagation" ->
        UIOperations.handle_event(event_name, params, socket)

      "search_timeline" ->
        UIOperations.handle_event(event_name, params, socket)

      "clear_search" ->
        UIOperations.handle_event(event_name, params, socket)

      "toggle_mobile_filters" ->
        UIOperations.handle_event(event_name, params, socket)

      # Tracking/Recommendations Operations
      "record_dwell_time" ->
        TrackingOperations.handle_event(event_name, params, socket)

      "record_dwell_times" ->
        TrackingOperations.handle_event(event_name, params, socket)

      "record_dismissal" ->
        TrackingOperations.handle_event(event_name, params, socket)

      "update_session_context" ->
        TrackingOperations.handle_event(event_name, params, socket)

      "not_interested" ->
        TrackingOperations.handle_event(event_name, params, socket)

      "hide_post" ->
        TrackingOperations.handle_event(event_name, params, socket)

      # Presence Events - delegate to shared handler
      "auto_away_timeout" ->
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(event_name, params, socket)

      "user_activity" ->
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(event_name, params, socket)

      "device_detected" ->
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(event_name, params, socket)

      "connection_changed" ->
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(event_name, params, socket)

      # Empty event - ignore silently (can happen from event bubbling)
      "" ->
        {:noreply, socket}

      nil ->
        {:noreply, socket}

      # Unknown event - log warning
      _ ->
        require Logger
        Logger.warning("Unknown event in TimelineLive.Index: #{event_name}")
        {:noreply, socket}
    end
  end
end
