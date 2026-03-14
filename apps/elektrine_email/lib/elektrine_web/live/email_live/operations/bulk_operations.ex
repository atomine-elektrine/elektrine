defmodule ElektrineWeb.EmailLive.Operations.BulkOperations do
  @moduledoc """
  Handles bulk message operations for email inbox.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Email
  alias Elektrine.Email.Cached

  def handle_event("bulk_action", %{"action" => action}, socket) do
    selected_messages = socket.assigns.selected_messages

    if selected_messages != [] do
      case action do
        "archive" ->
          bulk_archive_messages(socket, selected_messages)

        "delete" ->
          bulk_delete_messages(socket, selected_messages)

        "delete_permanently" ->
          bulk_delete_permanently_messages(socket, selected_messages)

        "recover" ->
          bulk_recover_messages(socket, selected_messages)

        "mark_read" ->
          bulk_mark_read_messages(socket, selected_messages)

        "mark_unread" ->
          bulk_mark_unread_messages(socket, selected_messages)

        "mark_spam" ->
          bulk_mark_spam_messages(socket, selected_messages)

        "mark_not_spam" ->
          bulk_mark_not_spam_messages(socket, selected_messages)

        "stack" ->
          bulk_stack_messages(socket, selected_messages)

        "clear_stack" ->
          bulk_clear_stack_messages(socket, selected_messages)

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, notify_error(socket, "No messages selected")}
    end
  end

  defp bulk_mark_read_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.mark_as_read(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(
        socket,
        socket.assigns.current_tab,
        %{"filter" => socket.assigns.current_filter},
        socket.assigns.pagination.page
      )

    {:noreply,
     socket
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> notify_info("Messages marked as read")}
  end

  defp bulk_mark_unread_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.mark_as_unread(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(
        socket,
        socket.assigns.current_tab,
        %{"filter" => socket.assigns.current_filter},
        socket.assigns.pagination.page
      )

    {:noreply,
     socket
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> notify_info("Messages marked as unread")}
  end

  defp bulk_archive_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.archive_message(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages archived successfully")}
  end

  defp bulk_delete_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id
    current_tab = socket.assigns.current_tab

    # If in trash tab, permanently delete. Otherwise, move to trash
    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          if current_tab == "trash" or message.deleted do
            Email.delete_message(message)
          else
            Email.update_message(message, %{deleted: true})
          end

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info(
       if current_tab == "trash",
         do: "Messages permanently deleted",
         else: "Messages moved to trash"
     )}
  end

  defp bulk_delete_permanently_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.delete_message(message)

        {:error, _} ->
          :ignore
      end
    end)

    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages permanently deleted")}
  end

  defp bulk_recover_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.update_message(message, %{deleted: false})

        {:error, _} ->
          :ignore
      end
    end)

    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages recovered from trash")}
  end

  defp bulk_mark_spam_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.mark_as_spam(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages marked as spam")}
  end

  defp bulk_mark_not_spam_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.mark_as_not_spam(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Ensure cache is invalidated immediately
    Cached.invalidate_message_caches(mailbox_id, socket.assigns.current_user.id)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{}, socket.assigns.pagination.page)

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages marked as not spam")}
  end

  defp bulk_stack_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.stack_message(message, "User deferred for later processing")

        {:error, _} ->
          :ignore
      end
    end)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{
        "filter" => socket.assigns.current_filter
      })

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages moved to Stack")}
  end

  defp bulk_clear_stack_messages(socket, message_ids) do
    mailbox = socket.assigns.mailbox
    mailbox_id = mailbox.id

    Enum.each(message_ids, fn id ->
      case Email.get_user_message(id, socket.assigns.current_user.id) do
        {:ok, message} ->
          Email.unstack_message(message)

        {:error, _} ->
          :ignore
      end
    end)

    # Reload current tab
    socket =
      load_tab_content(socket, socket.assigns.current_tab, %{
        "filter" => socket.assigns.current_filter
      })

    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:unread_count, Cached.unread_count(mailbox_id))
     |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox_id))
     |> assign(:digest_count, Cached.unread_feed_count(mailbox_id))
     |> assign(:ledger_count, Cached.unread_ledger_count(mailbox_id))
     |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox_id))
     |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox_id))
     |> notify_info("Messages removed from Stack")}
  end

  # Helper function for loading tab content
  defp load_tab_content(socket, tab, params, page \\ 1) do
    mailbox = socket.assigns.mailbox
    user = socket.assigns.current_user
    per_page = 20

    case tab do
      "inbox" ->
        filter = params["filter"] || "inbox"

        socket =
          if filter == "aliases" do
            # Handle aliases specially - no pagination needed
            aliases = Email.list_aliases(user.id)
            alias_changeset = Email.change_alias(%Email.Alias{})
            mailbox_changeset = Email.change_mailbox_forwarding(mailbox)

            socket
            |> assign(:aliases, aliases)
            |> assign(:alias_form, to_form(alias_changeset))
            |> assign(:mailbox_form, to_form(mailbox_changeset))
            |> assign(:messages, [])
            |> assign(:pagination, %{
              page: 1,
              per_page: per_page,
              total_count: 0,
              total_pages: 0,
              has_next: false,
              has_prev: false
            })
          else
            pagination = load_inbox_messages_paginated(mailbox.id, filter, page, per_page)

            socket
            |> assign(:messages, pagination.messages)
            |> assign(:pagination, pagination)
          end

        socket
        |> assign(:current_filter, filter)

      "sent" ->
        pagination = Email.list_sent_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "spam" ->
        pagination = Email.list_spam_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "trash" ->
        pagination = Email.list_trash_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "archive" ->
        pagination = Email.list_archived_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "search" ->
        query = params["q"] || ""

        results =
          if String.trim(query) != "" do
            Email.search_messages(mailbox.id, query, page, per_page)
          else
            %{
              messages: [],
              total_count: 0,
              page: page,
              per_page: per_page,
              total_pages: 0,
              has_next: false,
              has_prev: false
            }
          end

        socket
        |> assign(:search_query, query)
        |> assign(:search_results, results)
        |> assign(:messages, results.messages || [])
        |> assign(:pagination, results)
        |> assign(:selected_messages, [])
        |> assign(:select_all, false)

      "contacts" ->
        socket
        |> assign(:contacts, Elektrine.Email.Contacts.list_contacts(user.id))
        |> assign(:groups, Elektrine.Email.Contacts.list_contact_groups(user.id))
        |> assign(:contact_search_query, "")
        |> assign(:filter_group_id, nil)
        |> assign(:show_contact_modal, false)
        |> assign(:editing_contact, nil)
        |> assign(:show_group_modal, false)
        |> assign(:editing_group, nil)
        |> assign(:messages, [])
        |> assign(:pagination, %{
          page: 1,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        })

      _ ->
        socket
        |> assign(:pagination, %{
          page: 1,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        })
    end
    |> assign(:selected_messages, [])
    |> assign(:select_all, false)
  end

  defp load_inbox_messages_paginated(mailbox_id, filter, page, per_page) do
    case filter do
      "unread" ->
        Email.list_unread_messages_paginated(mailbox_id, page, per_page)

      "read" ->
        Email.list_read_messages_paginated(mailbox_id, page, per_page)

      "digest" ->
        Email.list_feed_messages_paginated(mailbox_id, page, per_page)

      "ledger" ->
        Email.list_ledger_messages_paginated(mailbox_id, page, per_page)

      "stack" ->
        Email.list_stack_messages_paginated(mailbox_id, page, per_page)

      "boomerang" ->
        Email.list_reply_later_messages_paginated(mailbox_id, page, per_page)

      _ ->
        Email.list_inbox_messages_paginated(mailbox_id, page, per_page)
    end
  end
end
