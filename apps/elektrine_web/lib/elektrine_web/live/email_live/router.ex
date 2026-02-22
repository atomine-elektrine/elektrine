defmodule ElektrineWeb.EmailLive.Router do
  @moduledoc """
  Routes events from EmailLive.Index to appropriate operation modules.
  """

  require Logger

  alias ElektrineWeb.EmailLive.Operations.{
    AliasOperations,
    BulkOperations,
    ComposeOperations,
    ContactOperations,
    MessageOperations,
    NavigationOperations,
    ReplyLaterOperations,
    SearchOperations,
    SelectionOperations
  }

  def route_event(event_name, params, socket) do
    case event_name do
      # Navigation operations
      "switch_tab" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "goto_page" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "next_page" ->
        NavigationOperations.handle_event(event_name, params, socket)

      "prev_page" ->
        NavigationOperations.handle_event(event_name, params, socket)

      # Search operations
      "search" ->
        SearchOperations.handle_event(event_name, params, socket)

      # Selection operations
      "toggle_message_selection" ->
        SelectionOperations.handle_event(event_name, params, socket)

      "select_all_messages" ->
        SelectionOperations.handle_event(event_name, params, socket)

      "deselect_all_messages" ->
        SelectionOperations.handle_event(event_name, params, socket)

      "toggle_message_selection_on_shift" ->
        SelectionOperations.handle_event(event_name, params, socket)

      # Bulk operations
      "bulk_action" ->
        BulkOperations.handle_event(event_name, params, socket)

      # Alias operations
      "create_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "toggle_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "delete_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "edit_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "cancel_edit_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "update_alias" ->
        AliasOperations.handle_event(event_name, params, socket)

      "update_mailbox_forwarding" ->
        AliasOperations.handle_event(event_name, params, socket)

      # Reply later operations
      "show_reply_later_modal" ->
        ReplyLaterOperations.handle_event(event_name, params, socket)

      "schedule_reply_later" ->
        ReplyLaterOperations.handle_event(event_name, params, socket)

      "close_reply_later_modal" ->
        ReplyLaterOperations.handle_event(event_name, params, socket)

      "cancel_reply_later" ->
        ReplyLaterOperations.handle_event(event_name, params, socket)

      "clear_reply_later" ->
        ReplyLaterOperations.handle_event(event_name, params, socket)

      # Single message operations
      "stack" ->
        MessageOperations.handle_event(event_name, params, socket)

      "move_to_digest" ->
        MessageOperations.handle_event(event_name, params, socket)

      "move_to_ledger" ->
        MessageOperations.handle_event(event_name, params, socket)

      "clear_stack" ->
        MessageOperations.handle_event(event_name, params, socket)

      "mark_as_unread" ->
        MessageOperations.handle_event(event_name, params, socket)

      # Compose/keyboard shortcut operations
      "show_keyboard_shortcuts" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "archive_message" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "mark_spam" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "navigate_to_compose" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "open_compose" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "tag_input_blur" ->
        ComposeOperations.handle_event(event_name, params, socket)

      "update_tag_input" ->
        ComposeOperations.handle_event(event_name, params, socket)

      # Contact operations
      "contact_search" ->
        ContactOperations.handle_event(event_name, params, socket)

      "new_contact" ->
        ContactOperations.handle_event(event_name, params, socket)

      "edit_contact" ->
        ContactOperations.handle_event(event_name, params, socket)

      "cancel_contact" ->
        ContactOperations.handle_event(event_name, params, socket)

      "save_contact" ->
        ContactOperations.handle_event(event_name, params, socket)

      "delete_contact" ->
        ContactOperations.handle_event(event_name, params, socket)

      "toggle_favorite" ->
        ContactOperations.handle_event(event_name, params, socket)

      "filter_by_group" ->
        ContactOperations.handle_event(event_name, params, socket)

      "new_group" ->
        ContactOperations.handle_event(event_name, params, socket)

      "cancel_group" ->
        ContactOperations.handle_event(event_name, params, socket)

      "save_group" ->
        ContactOperations.handle_event(event_name, params, socket)

      # Label operations
      "add_label" ->
        MessageOperations.handle_event(event_name, params, socket)

      "remove_label" ->
        MessageOperations.handle_event(event_name, params, socket)

      # Folder operations
      "move_to_folder" ->
        MessageOperations.handle_event(event_name, params, socket)

      # Block sender
      "block_sender_from_message" ->
        MessageOperations.handle_event(event_name, params, socket)

      # No-op to stop event propagation (used by dropdowns)
      "stop_propagation" ->
        {:noreply, socket}

      _ ->
        Logger.warning("Unknown event in EmailLive.Index: #{event_name}")
        {:noreply, socket}
    end
  end
end
