defmodule ElektrineWeb.EmailLive.Operations.ComposeOperations do
  @moduledoc """
  Handles compose and keyboard shortcut operations for email inbox.
  """

  import Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Email

  def handle_event("show_keyboard_shortcuts", _params, socket) do
    # Push event to client - will be handled by any KeyboardShortcuts hook
    {:noreply, push_event(socket, "show-keyboard-shortcuts", %{})}
  end

  def handle_event("archive_message", %{"message_id" => message_id}, socket) do
    # Archive (stack) the message - validate message_id and fetch message first
    case Integer.parse(message_id) do
      {id, ""} ->
        case Email.get_user_message(id, socket.assigns.current_user.id) do
          {:ok, message} ->
            case Email.stack_message(message, "User archived via keyboard shortcut") do
              {:ok, _message} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Message archived")
                 |> push_patch(to: ~p"/email?tab=#{socket.assigns.active_tab}")}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to archive message")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Message not found")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid message")}
    end
  end

  # Handle archive without message_id (no message selected)
  def handle_event("archive_message", _params, socket) do
    {:noreply, put_flash(socket, :warning, "Please select a message first")}
  end

  def handle_event("mark_spam", %{"message_id" => message_id}, socket) do
    # Mark message as spam - validate message_id and fetch message first
    case Integer.parse(message_id) do
      {id, ""} ->
        case Email.get_user_message(id, socket.assigns.current_user.id) do
          {:ok, message} ->
            case Email.mark_as_spam(message) do
              {:ok, _message} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Message marked as spam")
                 |> push_patch(to: ~p"/email?tab=#{socket.assigns.active_tab}")}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to mark message as spam")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Message not found")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid message")}
    end
  end

  # Handle mark_spam without message_id (no message selected)
  def handle_event("mark_spam", _params, socket) do
    {:noreply, put_flash(socket, :warning, "Please select a message first")}
  end

  def handle_event("navigate_to_compose", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/email/compose")}
  end

  def handle_event("open_compose", %{"mode" => mode, "message_id" => message_id}, socket) do
    url = ~p"/email/compose?mode=#{mode}&message_id=#{message_id}"
    {:noreply, push_navigate(socket, to: url)}
  end

  # Handle when no message is selected (keyboard shortcuts)
  def handle_event("open_compose", %{"mode" => _mode}, socket) do
    # If no message_id is provided, just open compose normally
    {:noreply, push_navigate(socket, to: ~p"/email/compose")}
  end

  # Handle tag input events from compose page (in case of navigation timing issues)
  def handle_event("tag_input_blur", _params, socket) do
    # Ignore - this event is for compose page only
    {:noreply, socket}
  end

  def handle_event("update_tag_input", _params, socket) do
    # Ignore - this event is for compose page only
    {:noreply, socket}
  end
end
