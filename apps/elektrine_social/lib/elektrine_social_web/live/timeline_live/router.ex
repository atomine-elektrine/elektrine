defmodule ElektrineSocialWeb.TimelineLive.Router do
  @moduledoc """
  Routes handle_event calls to the appropriate operation module.
  This module acts as a dispatcher to keep the main LiveView clean.
  """

  require Logger

  alias ElektrineSocialWeb.TimelineLive.Operations.{
    BookmarkFolderOperations,
    ImageOperations,
    NavigationOperations,
    PostOperations,
    ReplyOperations,
    SocialOperations,
    TrackingOperations,
    UIOperations,
    VotingOperations
  }

  @operation_events %{
    # NavigationOperations
    "navigate_to_embedded_post" => NavigationOperations,
    "navigate_to_gallery_post" => NavigationOperations,
    "navigate_to_origin" => NavigationOperations,
    "navigate_to_post" => NavigationOperations,
    "navigate_to_profile" => NavigationOperations,
    "navigate_to_remote_post" => NavigationOperations,
    "navigate_to_remote_profile" => NavigationOperations,
    "open_external_link" => NavigationOperations,
    "open_external_post" => NavigationOperations,
    # PostOperations
    "autosave_draft" => PostOperations,
    "close_filter_dropdown" => PostOperations,
    "copy_post_link" => PostOperations,
    "create_post" => PostOperations,
    "delete_draft" => PostOperations,
    "delete_post" => PostOperations,
    "delete_post_admin" => PostOperations,
    "edit_draft" => PostOperations,
    "filter_timeline" => PostOperations,
    "hide_drafts" => PostOperations,
    "load-more" => PostOperations,
    "load_more_posts" => PostOperations,
    "load_queued_posts" => PostOperations,
    "mute_remote_actor" => PostOperations,
    "mute_thread" => PostOperations,
    "mute_user" => PostOperations,
    "publish_draft" => PostOperations,
    "report_post" => PostOperations,
    "save_draft" => PostOperations,
    "seed_starter_pack" => PostOperations,
    "set_filter" => PostOperations,
    "set_software_filter" => PostOperations,
    "show_drafts" => PostOperations,
    "toggle_content_warning" => PostOperations,
    "toggle_filter_dropdown" => PostOperations,
    "toggle_hide_boosts" => PostOperations,
    "toggle_hide_replies" => PostOperations,
    "toggle_post_composer" => PostOperations,
    "unmute_remote_actor" => PostOperations,
    "unmute_thread" => PostOperations,
    "unmute_user" => PostOperations,
    "update_content_warning" => PostOperations,
    "update_post_content" => PostOperations,
    "update_post_content_live" => PostOperations,
    "update_post_title" => PostOperations,
    "update_scheduled_at" => PostOperations,
    "update_visibility" => PostOperations,
    "view_post" => PostOperations,
    # ImageOperations
    "cancel_upload" => ImageOperations,
    "clear_pending_images" => ImageOperations,
    "close_image_modal" => ImageOperations,
    "close_image_upload" => ImageOperations,
    "next_image" => ImageOperations,
    "next_media_post" => ImageOperations,
    "open_image_modal" => ImageOperations,
    "open_image_upload" => ImageOperations,
    "prev_image" => ImageOperations,
    "prev_media_post" => ImageOperations,
    "upload_timeline_images" => ImageOperations,
    "validate_timeline_upload" => ImageOperations,
    # VotingOperations
    "boost_post" => VotingOperations,
    "close_quote_modal" => VotingOperations,
    "downvote_post" => VotingOperations,
    "like_post" => VotingOperations,
    "quote_post" => VotingOperations,
    "react_to_post" => VotingOperations,
    "save_post" => VotingOperations,
    "save_rss_item" => VotingOperations,
    "submit_quote" => VotingOperations,
    "toggle_modal_like" => VotingOperations,
    "unboost_post" => VotingOperations,
    "undownvote_post" => VotingOperations,
    "unlike_post" => VotingOperations,
    "unsave_post" => VotingOperations,
    "unsave_rss_item" => VotingOperations,
    "update_quote_content" => VotingOperations,
    "vote_poll" => VotingOperations,
    "vote_remote_poll" => VotingOperations,
    # BookmarkFolderOperations
    "cancel_edit_bookmark_folder" => BookmarkFolderOperations,
    "create_bookmark_folder" => BookmarkFolderOperations,
    "delete_bookmark_folder" => BookmarkFolderOperations,
    "edit_bookmark_folder" => BookmarkFolderOperations,
    "move_saved_item" => BookmarkFolderOperations,
    "select_bookmark_folder" => BookmarkFolderOperations,
    "toggle_bookmark_folder_manager" => BookmarkFolderOperations,
    "update_bookmark_folder" => BookmarkFolderOperations,
    # SocialOperations
    "discuss_privately" => SocialOperations,
    "follow_remote_user" => SocialOperations,
    "follow_suggested_people" => SocialOperations,
    "import_starter_rss_feeds" => SocialOperations,
    "preview_remote_user" => SocialOperations,
    "refresh_suggestions" => SocialOperations,
    "toggle_follow" => SocialOperations,
    "toggle_follow_remote" => SocialOperations,
    # ReplyOperations
    "cancel_reply" => ReplyOperations,
    "create_timeline_reply" => ReplyOperations,
    "load_remote_replies" => ReplyOperations,
    "show_reply_form" => ReplyOperations,
    "show_reply_to_reply_form" => ReplyOperations,
    "update_reply_content" => ReplyOperations,
    "view_original_context" => ReplyOperations,
    # UIOperations
    "clear_search" => UIOperations,
    "close_dropdown" => UIOperations,
    "close_report_modal" => UIOperations,
    "search_timeline" => UIOperations,
    "stop_event" => UIOperations,
    "stop_propagation" => UIOperations,
    "toggle_mobile_filters" => UIOperations,
    # TrackingOperations
    "hide_post" => TrackingOperations,
    "not_interested" => TrackingOperations,
    "record_dismissal" => TrackingOperations,
    "record_dwell_time" => TrackingOperations,
    "record_dwell_times" => TrackingOperations,
    "restore_session_continuity" => TrackingOperations,
    "update_session_context" => TrackingOperations
  }

  @presence_events ~w(auto_away_timeout user_activity device_detected connection_changed)

  @doc """
  Routes an event to the appropriate operation module based on the event name.
  Returns {:noreply, socket} tuple.
  """
  def route_event(event_name, params, socket) when is_map_key(@operation_events, event_name) do
    @operation_events[event_name].handle_event(event_name, params, socket)
  end

  def route_event(event_name, params, socket) when event_name in @presence_events do
    ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(event_name, params, socket)
  end

  def route_event(event_name, _params, socket) when event_name in [nil, ""] do
    {:noreply, socket}
  end

  def route_event(event_name, _params, socket) do
    Logger.warning("Unknown event in TimelineLive.Index: #{event_name}")
    {:noreply, socket}
  end
end
