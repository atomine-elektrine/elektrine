defmodule ElektrineWeb.EmailLive.Raw do
  use ElektrineWeb, :live_view
  import ElektrineWeb.Live.NotificationHelpers
  import ElektrineWeb.EmailLive.EmailHelpers
  import ElektrineWeb.Components.Platform.ElektrineNav

  alias Elektrine.Email

  @impl true
  def mount(%{"id" => message_identifier}, session, socket) do
    user = socket.assigns.current_user
    mailbox = get_or_create_mailbox(user)

    # Get fresh user data to ensure latest locale preference
    fresh_user = Elektrine.Accounts.get_user!(user.id)

    # Set locale for this LiveView process
    locale = fresh_user.locale || session["locale"] || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Get storage info and unread count early (needed for sidebar in template)
    unread_count = Email.unread_count(mailbox.id)
    storage_info = Elektrine.Accounts.Storage.get_storage_info(user.id)

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
          {:ok,
           socket
           |> assign(:mailbox, mailbox)
           |> assign(:unread_count, unread_count)
           |> assign(:storage_info, storage_info)
           |> push_navigate(to: ~p"/email/#{verified_message.hash}/raw")}
        else
          {:ok,
           socket
           |> assign(:page_title, "Raw Email - #{verified_message.subject}")
           |> assign(:mailbox, mailbox)
           |> assign(:message, verified_message)
           |> assign(:unread_count, unread_count)
           |> assign(:storage_info, storage_info)}
        end

      {:error, _} ->
        {:ok,
         socket
         |> assign(:mailbox, mailbox)
         |> assign(:unread_count, unread_count)
         |> assign(:storage_info, storage_info)
         |> notify_error("Message not found")
         |> push_navigate(to: ~p"/email")}
    end
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
end
