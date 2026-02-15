defmodule ElektrineWeb.EmailLive.Show do
  use ElektrineWeb, :live_view
  import ElektrineWeb.EmailLive.EmailHelpers
  import ElektrineWeb.Live.NotificationHelpers
  import ElektrineWeb.Components.Platform.ElektrineNav

  alias Elektrine.Email

  @impl true
  def mount(%{"id" => message_identifier} = params, session, socket) do
    user = socket.assigns.current_user
    mailbox = get_or_create_mailbox(user)

    # Get fresh user data to ensure latest locale preference
    fresh_user = Elektrine.Accounts.get_user!(user.id)

    # Set locale for this LiveView process
    locale = fresh_user.locale || session["locale"] || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Try to find message by hash first, then by ID
    # Both lookups now validate ownership
    message_result =
      case Email.get_message_by_hash(message_identifier) do
        %Email.Message{} = msg ->
          # Validate ownership for hash-based lookup
          Email.get_user_message(msg.id, user.id)

        nil ->
          # Fallback to ID lookup for backwards compatibility
          case Integer.parse(message_identifier) do
            {id, ""} -> Email.get_user_message(id, user.id)
            _ -> {:error, :invalid_identifier}
          end
      end

    case message_result do
      {:ok, verified_message} ->
        # If accessed by ID instead of hash, redirect to hash URL
        if message_identifier != verified_message.hash && verified_message.hash do
          return_to = Map.get(params, "return_to", "inbox")
          return_filter = Map.get(params, "filter", "inbox")

          {:ok,
           socket
           |> push_navigate(
             to:
               ~p"/email/view/#{verified_message.hash}?return_to=#{return_to}&filter=#{return_filter}"
           )}
        else
          load_message(verified_message, params, socket, user, mailbox)
        end

      {:error, _} ->
        {:ok,
         socket
         |> notify_error("Message not found or access denied")
         |> push_navigate(to: ~p"/email")}
    end
  end

  defp load_message(message, params, socket, user, mailbox) do
    unread_count = Email.unread_count(mailbox.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "mailbox:#{mailbox.id}")
    end

    # Mark message as read if not already read
    unless message.read do
      {:ok, _} = Email.mark_as_read(message)
    end

    # Get storage info
    storage_info = Elektrine.Accounts.Storage.get_storage_info(user.id)

    # Store return navigation info
    return_to = Map.get(params, "return_to", "inbox")
    return_filter = Map.get(params, "filter", "inbox")

    {:ok,
     socket
     |> assign(:page_title, message.subject)
     |> assign(:mailbox, mailbox)
     |> assign(:message, message)
     |> assign(:unread_count, unread_count)
     |> assign(:storage_info, storage_info)
     |> assign(:return_to, return_to)
     |> assign(:return_filter, return_filter)
     |> assign(:show_reply_later_modal, false)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # SECURE DELETE: Use ownership validation
    case Email.get_user_message(String.to_integer(id), user.id) do
      {:ok, message} ->
        # If already in trash, permanently delete. Otherwise, move to trash
        if message.deleted do
          {:ok, _} = Email.delete_message(message)

          {:noreply,
           socket
           |> notify_info("Message permanently deleted")
           |> push_navigate(to: ~p"/email?tab=trash")}
        else
          {:ok, _} = Email.update_message(message, %{deleted: true})

          {:noreply,
           socket
           |> notify_info("Message moved to trash")
           |> push_navigate(to: ~p"/email")}
        end

      {:error, :access_denied} ->
        require Logger
        Logger.warning("User #{user.id} attempted to delete unauthorized message #{id}")

        {:noreply,
         socket
         |> notify_error("You don't have permission to delete this message")
         |> push_navigate(to: ~p"/email")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> notify_error("Message not found")
         |> push_navigate(to: ~p"/email")}
    end
  end

  def handle_event("recover", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # Recover message from trash
    case Email.get_user_message(String.to_integer(id), user.id) do
      {:ok, message} ->
        {:ok, _} = Email.update_message(message, %{deleted: false})

        {:noreply,
         socket
         |> notify_info("Message recovered from trash")
         |> push_navigate(to: ~p"/email")}

      {:error, :access_denied} ->
        {:noreply,
         socket
         |> notify_error("You don't have permission to recover this message")
         |> push_navigate(to: ~p"/email?tab=trash")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> notify_error("Message not found")
         |> push_navigate(to: ~p"/email?tab=trash")}
    end
  end

  def handle_event("reply", _params, socket) do
    message = socket.assigns.message
    return_to = socket.assigns.return_to
    return_filter = socket.assigns.return_filter

    # Navigate to compose in reply mode (sender only)
    {:noreply,
     socket
     |> push_navigate(
       to:
         ~p"/email/compose?mode=reply&message_id=#{message.id}&return_to=#{return_to}&filter=#{return_filter}"
     )}
  end

  def handle_event("reply_all", _params, socket) do
    message = socket.assigns.message
    return_to = socket.assigns.return_to
    return_filter = socket.assigns.return_filter

    # Navigate to compose in reply_all mode (all recipients)
    {:noreply,
     socket
     |> push_navigate(
       to:
         ~p"/email/compose?mode=reply_all&message_id=#{message.id}&return_to=#{return_to}&filter=#{return_filter}"
     )}
  end

  def handle_event("forward", _params, socket) do
    message = socket.assigns.message
    return_to = socket.assigns.return_to
    return_filter = socket.assigns.return_filter

    # Navigate to compose in forward mode
    {:noreply,
     socket
     |> push_navigate(
       to:
         ~p"/email/compose?mode=forward&message_id=#{message.id}&return_to=#{return_to}&filter=#{return_filter}"
     )}
  end

  def handle_event("mark_unread", _params, socket) do
    message = socket.assigns.message
    mailbox = socket.assigns.mailbox

    if message.mailbox_id == mailbox.id do
      {:ok, updated_message} = Email.mark_as_unread(message)
      unread_count = Email.unread_count(mailbox.id)

      {:noreply,
       socket
       |> assign(:message, updated_message)
       |> assign(:unread_count, unread_count)
       |> notify_info("Message marked as unread")}
    else
      {:noreply,
       socket
       |> notify_error("Unable to mark message as unread")}
    end
  end

  def handle_event("save_message", _params, socket) do
    message = socket.assigns.message

    case Elektrine.Email.stack_message(message) do
      {:ok, updated_message} ->
        {:noreply,
         socket
         |> assign(:message, updated_message)
         |> notify_info("Message saved to Stack")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> notify_error("Unable to save message")}
    end
  end

  def handle_event("show_reply_later_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, true)}
  end

  def handle_event("schedule_reply_later", %{"days" => days}, socket) do
    message = socket.assigns.message
    days_int = String.to_integer(days)

    reply_at =
      DateTime.utc_now()
      |> DateTime.add(days_int, :day)
      |> DateTime.truncate(:second)

    case Elektrine.Email.reply_later_message(message, reply_at) do
      {:ok, updated_message} ->
        {:noreply,
         socket
         |> assign(:message, updated_message)
         |> assign(:show_reply_later_modal, false)
         |> notify_info("Message scheduled for reply in #{days_int} day(s)")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> notify_error("Unable to schedule reply")}
    end
  end

  def handle_event("close_reply_later_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, false)}
  end

  def handle_event("clear_reply_later", %{"id" => id}, socket) do
    message = socket.assigns.message

    if to_string(message.id) == id do
      case Elektrine.Email.clear_reply_later(message) do
        {:ok, updated_message} ->
          {:noreply,
           socket
           |> assign(:message, updated_message)
           |> notify_info("Reply later schedule cleared")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> notify_error("Unable to clear reply later")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_keyboard_shortcuts", _params, socket) do
    # Push event to client to show keyboard shortcuts modal
    {:noreply, push_event(socket, "show-keyboard-shortcuts", %{})}
  end

  def handle_event("download_attachment", %{"attachment-id" => attachment_id}, socket) do
    message = socket.assigns.message
    attachment = get_in(message.attachments, [attachment_id])

    if attachment && attachment["data"] do
      # Decode base64 data and send as download
      {:noreply,
       socket
       |> push_event("download_file", %{
         filename: attachment["filename"],
         data: attachment["data"],
         content_type: attachment["content_type"]
       })}
    else
      {:noreply,
       socket
       |> notify_error("Attachment not found or no data available")}
    end
  end

  # Handle tag input blur events from compose components (no-op)
  def handle_event("tag_input_blur", _params, socket) do
    {:noreply, socket}
  end

  # Catch-all for unhandled events (e.g., connection_changed from JS)
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_email, _message}, socket) do
    mailbox = socket.assigns.mailbox

    # Update unread count in real-time
    unread_count = Email.unread_count(mailbox.id)

    {:noreply,
     socket
     |> assign(:unread_count, unread_count)}
  end

  def handle_info({:unread_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :unread_count, new_count)}
  end

  def handle_info({:notification_count_updated, _new_count} = msg, socket) do
    ElektrineWeb.Live.NotificationHelpers.handle_notification_count_update(msg, socket)
  end

  def handle_info(
        {:storage_updated, %{storage_used_bytes: _used_bytes, user_id: user_id}},
        socket
      ) do
    # Refresh storage info when storage is updated
    if socket.assigns.current_user.id == user_id do
      storage_info = Elektrine.Accounts.Storage.get_storage_info(user_id)
      {:noreply, assign(socket, :storage_info, storage_info)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_flags_updated, %{message_id: message_id, updates: _updates}}, socket) do
    # Message flags were updated via IMAP, reload if viewing this message
    if socket.assigns.message.id == message_id do
      case Email.get_message(message_id, socket.assigns.mailbox.id) do
        nil ->
          {:noreply, socket}

        updated_message ->
          {:noreply, assign(socket, :message, updated_message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_updated, updated_message}, socket) do
    # Message was updated (moved, deleted, etc.), reload if viewing this message
    if socket.assigns.message.id == updated_message.id do
      {:noreply, assign(socket, :message, updated_message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_deleted, message_id}, socket) do
    # Message was deleted via IMAP, redirect to inbox if viewing this message
    if socket.assigns.message.id == message_id do
      {:noreply,
       socket
       |> put_flash(:info, "This message was deleted")
       |> push_navigate(to: ~p"/email")}
    else
      {:noreply, socket}
    end
  end

  # Catch-all clause to handle any unexpected messages
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_or_create_mailbox(user) do
    case Email.get_user_mailbox(user.id) do
      nil ->
        {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
        mailbox

      mailbox ->
        mailbox
    end
  end

  # Helper function to check if Reply All would include additional recipients
  def has_additional_recipients?(message) do
    # Add TO recipients
    to_recipients =
      if message.to && String.trim(message.to) != "" do
        message.to |> String.split(~r/[,;]\s*/) |> Enum.map(&String.trim/1)
      else
        []
      end

    # Add CC recipients  
    cc_recipients =
      if message.cc && String.trim(message.cc) != "" do
        message.cc |> String.split(~r/[,;]\s*/) |> Enum.map(&String.trim/1)
      else
        []
      end

    # Total recipients beyond the sender
    total_recipients = (to_recipients ++ cc_recipients) |> Enum.uniq() |> length()

    # If it's a received message, check if there were other TO/CC recipients besides us
    # If it's a sent message, check if we sent to multiple people
    case message.status do
      "sent" -> total_recipients > 1
      _ -> total_recipients > 1 || cc_recipients != []
    end
  end

  # Helper functions for return navigation
  defp get_return_url(assigns) do
    return_to = assigns[:return_to] || "inbox"
    return_filter = assigns[:return_filter] || "inbox"

    case return_to do
      "sent" -> ~p"/email?tab=sent"
      "spam" -> ~p"/email?tab=spam"
      "archive" -> ~p"/email?tab=archive"
      "search" -> ~p"/email?tab=search"
      "inbox" when return_filter != "inbox" -> ~p"/email?tab=inbox&filter=#{return_filter}"
      _ -> ~p"/email?tab=inbox"
    end
  end

  defp get_back_button_text(assigns) do
    return_to = assigns[:return_to] || "inbox"
    return_filter = assigns[:return_filter] || "inbox"

    case return_to do
      "sent" ->
        gettext("Back to Sent")

      "spam" ->
        gettext("Back to Spam")

      "archive" ->
        gettext("Back to Archive")

      "search" ->
        gettext("Back to Search")

      "inbox" ->
        case return_filter do
          "bulk_mail" -> gettext("Back to Bulk Mail")
          "paper_trail" -> gettext("Back to Paper Trail")
          "the_pile" -> gettext("Back to The Pile")
          "boomerang" -> gettext("Back to Boomerang")
          "aliases" -> gettext("Back to Aliases")
          "unread" -> gettext("Back to Unread")
          "read" -> gettext("Back to Read")
          _ -> gettext("Back to Inbox")
        end

      _ ->
        gettext("Back to Inbox")
    end
  end
end
