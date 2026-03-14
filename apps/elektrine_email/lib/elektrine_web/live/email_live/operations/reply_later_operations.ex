defmodule ElektrineWeb.EmailLive.Operations.ReplyLaterOperations do
  @moduledoc """
  Handles reply later (boomerang) operations for email inbox.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Email
  alias Elektrine.Email.Cached

  def handle_event("show_reply_later_modal", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:reply_later_message, message)
         |> assign(:show_reply_later_modal, true)}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("schedule_reply_later", %{"id" => id, "days" => days}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        days_int = String.to_integer(days)
        reply_at = DateTime.add(DateTime.utc_now(), days_int * 24 * 60 * 60, :second)

        {:ok, _} = Email.reply_later_message(message, reply_at)

        # Refresh current tab
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply,
         socket
         |> assign(:show_reply_later_modal, false)
         |> assign(:reply_later_message, nil)
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message scheduled for reply in #{days_int} day(s)")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("close_reply_later_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, false)
     |> assign(:reply_later_message, nil)}
  end

  def handle_event("cancel_reply_later", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, false)
     |> assign(:reply_later_message, nil)}
  end

  def handle_event("clear_reply_later", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.clear_reply_later(message)

        # Refresh current tab
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply,
         socket
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Reply later schedule cleared")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  # Helper function for loading tab content
  defp load_tab_content(socket, tab, params, page) do
    mailbox = socket.assigns.mailbox
    user = socket.assigns.current_user
    per_page = 20

    case tab do
      "inbox" ->
        filter = params["filter"] || "inbox"

        socket =
          if filter == "aliases" do
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
      "unread" -> Email.list_unread_messages_paginated(mailbox_id, page, per_page)
      "read" -> Email.list_read_messages_paginated(mailbox_id, page, per_page)
      "digest" -> Email.list_feed_messages_paginated(mailbox_id, page, per_page)
      "ledger" -> Email.list_ledger_messages_paginated(mailbox_id, page, per_page)
      "stack" -> Email.list_stack_messages_paginated(mailbox_id, page, per_page)
      "boomerang" -> Email.list_reply_later_messages_paginated(mailbox_id, page, per_page)
      _ -> Email.list_inbox_messages_paginated(mailbox_id, page, per_page)
    end
  end
end
