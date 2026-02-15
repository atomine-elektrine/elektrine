defmodule ElektrineWeb.EmailLive.Operations.MessageOperations do
  @moduledoc """
  Handles single message operations for email inbox.
  """

  require Logger

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Email
  alias Elektrine.Email.Cached

  def handle_event("stack", %{"id" => id}, socket) do
    Logger.info("Set aside event called for message #{id}")

    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        Logger.info("Setting aside message #{id}")
        {:ok, _} = Email.stack_message(message, "User deferred for later processing")

        # Ensure cache is invalidated immediately
        Cached.invalidate_message_caches(
          socket.assigns.mailbox.id,
          socket.assigns.current_user.id
        )

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
         |> assign(:unread_count, Cached.unread_count(socket.assigns.mailbox.id))
         |> assign(:inbox_unread_count, Cached.unread_inbox_count(socket.assigns.mailbox.id))
         |> assign(:digest_count, Cached.unread_feed_count(socket.assigns.mailbox.id))
         |> assign(:ledger_count, Cached.unread_ledger_count(socket.assigns.mailbox.id))
         |> assign(:stack_unread_count, Cached.unread_stack_count(socket.assigns.mailbox.id))
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message moved to Stack")}

      {:error, _} ->
        Logger.warning("Message #{id} not found or access denied")

        {:noreply,
         socket
         |> notify_info("Message not found")}
    end
  end

  def handle_event("move_to_digest", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.move_to_digest(message)

        # Ensure cache is invalidated immediately
        Cached.invalidate_message_caches(
          socket.assigns.mailbox.id,
          socket.assigns.current_user.id
        )

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
         |> assign(:unread_count, Cached.unread_count(socket.assigns.mailbox.id))
         |> assign(:inbox_unread_count, Cached.unread_inbox_count(socket.assigns.mailbox.id))
         |> assign(:digest_count, Cached.unread_feed_count(socket.assigns.mailbox.id))
         |> assign(:ledger_count, Cached.unread_ledger_count(socket.assigns.mailbox.id))
         |> assign(:stack_unread_count, Cached.unread_stack_count(socket.assigns.mailbox.id))
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message moved to Digest")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("move_to_ledger", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.move_to_ledger(message)

        # Ensure cache is invalidated immediately
        Cached.invalidate_message_caches(
          socket.assigns.mailbox.id,
          socket.assigns.current_user.id
        )

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
         |> assign(:unread_count, Cached.unread_count(socket.assigns.mailbox.id))
         |> assign(:inbox_unread_count, Cached.unread_inbox_count(socket.assigns.mailbox.id))
         |> assign(:digest_count, Cached.unread_feed_count(socket.assigns.mailbox.id))
         |> assign(:ledger_count, Cached.unread_ledger_count(socket.assigns.mailbox.id))
         |> assign(:stack_unread_count, Cached.unread_stack_count(socket.assigns.mailbox.id))
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message moved to Ledger")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("clear_stack", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.unstack_message(message)

        # Ensure cache is invalidated immediately
        Cached.invalidate_message_caches(
          socket.assigns.mailbox.id,
          socket.assigns.current_user.id
        )

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
         |> assign(:unread_count, Cached.unread_count(socket.assigns.mailbox.id))
         |> assign(:inbox_unread_count, Cached.unread_inbox_count(socket.assigns.mailbox.id))
         |> assign(:digest_count, Cached.unread_feed_count(socket.assigns.mailbox.id))
         |> assign(:ledger_count, Cached.unread_ledger_count(socket.assigns.mailbox.id))
         |> assign(:stack_unread_count, Cached.unread_stack_count(socket.assigns.mailbox.id))
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message removed from Stack")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("mark_as_unread", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.mark_as_unread(message)

        # Ensure cache is invalidated immediately
        Cached.invalidate_message_caches(
          socket.assigns.mailbox.id,
          socket.assigns.current_user.id
        )

        # Refresh current tab but keep message in view since we're just changing read status
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply,
         socket
         |> assign(:unread_count, Cached.unread_count(socket.assigns.mailbox.id))
         |> assign(:inbox_unread_count, Cached.unread_inbox_count(socket.assigns.mailbox.id))
         |> assign(:digest_count, Cached.unread_feed_count(socket.assigns.mailbox.id))
         |> assign(:ledger_count, Cached.unread_ledger_count(socket.assigns.mailbox.id))
         |> assign(:stack_unread_count, Cached.unread_stack_count(socket.assigns.mailbox.id))
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message marked as unread")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  # Label management
  def handle_event("add_label", %{"message_id" => message_id, "label_id" => label_id}, socket) do
    result =
      Email.add_label_to_message(String.to_integer(message_id), String.to_integer(label_id))

    case result do
      :ok ->
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply, notify_info(socket, "Label added")}

      {:ok, _} ->
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply, notify_info(socket, "Label added")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to add label")}
    end
  end

  def handle_event("remove_label", %{"message_id" => message_id, "label_id" => label_id}, socket) do
    result =
      Email.remove_label_from_message(String.to_integer(message_id), String.to_integer(label_id))

    case result do
      :ok ->
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply, notify_info(socket, "Label removed")}

      {:ok, _} ->
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply, notify_info(socket, "Label removed")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to remove label")}
    end
  end

  # Move to folder
  def handle_event(
        "move_to_folder",
        %{"message_id" => message_id, "folder_id" => folder_id},
        socket
      ) do
    user_id = socket.assigns.current_user.id

    folder_id_int =
      case folder_id do
        "" -> nil
        id -> String.to_integer(id)
      end

    case Email.get_user_message(String.to_integer(message_id), user_id) do
      {:ok, message} ->
        case Email.move_message_to_folder(message, folder_id_int) do
          {:ok, _} ->
            socket =
              load_tab_content(
                socket,
                socket.assigns.current_tab,
                %{"filter" => socket.assigns.current_filter},
                socket.assigns.pagination.page
              )

            {:noreply,
             notify_info(socket, if(folder_id_int, do: "Moved to folder", else: "Moved to inbox"))}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to move message")}
        end

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  # Block sender from message
  def handle_event("block_sender_from_message", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_user_message(String.to_integer(message_id), user_id) do
      {:ok, message} ->
        from = message.from || ""

        email =
          case Regex.run(~r/<([^>]+)>/, from) do
            [_, extracted] -> extracted
            _ -> from
          end
          |> String.trim()
          |> String.downcase()

        if email != "" do
          case Email.block_email(user_id, email, "Blocked from message") do
            {:ok, _} ->
              {:noreply, notify_info(socket, "Sender #{email} blocked")}

            {:error, _} ->
              {:noreply, notify_error(socket, "Failed to block sender")}
          end
        else
          {:noreply, notify_error(socket, "Could not determine sender email")}
        end

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
