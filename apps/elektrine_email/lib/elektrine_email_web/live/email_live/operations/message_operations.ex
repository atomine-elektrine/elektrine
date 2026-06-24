defmodule ElektrineEmailWeb.EmailLive.Operations.MessageOperations do
  @moduledoc """
  Handles single message operations for email inbox.
  """

  require Logger

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  import ElektrineEmailWeb.EmailLive.Operations.TabContent, only: [load_tab_content: 4]

  alias Elektrine.Email
  alias Elektrine.Email.Cached
  alias Elektrine.Utils.SafeConvert

  def handle_event("stack", %{"id" => id}, socket) do
    Logger.info("Set aside event called for message #{id}")

    case Email.get_user_message(event_id(id), socket.assigns.current_user.id) do
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
    case Email.get_user_message(event_id(id), socket.assigns.current_user.id) do
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
    case Email.get_user_message(event_id(id), socket.assigns.current_user.id) do
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
    case Email.get_user_message(event_id(id), socket.assigns.current_user.id) do
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
    case Email.get_user_message(event_id(id), socket.assigns.current_user.id) do
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
    user_id = socket.assigns.current_user.id
    message_id_int = event_id(message_id)
    label_id_int = event_id(label_id)

    with {:ok, _message} <- Email.get_user_message(message_id_int, user_id),
         %{} <- Email.get_label(label_id_int, user_id) do
      result = Email.add_label_to_message(message_id_int, label_id_int)

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
    else
      _ ->
        {:noreply, notify_error(socket, "Failed to add label")}
    end
  end

  def handle_event("remove_label", %{"message_id" => message_id, "label_id" => label_id}, socket) do
    user_id = socket.assigns.current_user.id
    message_id_int = event_id(message_id)
    label_id_int = event_id(label_id)

    with {:ok, _message} <- Email.get_user_message(message_id_int, user_id),
         %{} <- Email.get_label(label_id_int, user_id) do
      result = Email.remove_label_from_message(message_id_int, label_id_int)

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
    else
      _ ->
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

    folder_id_int = optional_event_id(folder_id)

    case Email.get_user_message(event_id(message_id), user_id) do
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

    case Email.get_user_message(event_id(message_id), user_id) do
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

  defp event_id(value) do
    case SafeConvert.parse_id(value) do
      {:ok, id} -> id
      {:error, :invalid_id} -> 0
    end
  end

  defp optional_event_id(value) when value in [nil, ""], do: nil
  defp optional_event_id(value), do: event_id(value)
end
