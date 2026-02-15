defmodule ElektrineWeb.ChatLive.Operations.ConversationOperations do
  @moduledoc """
  Handles conversation management: selection, search, pin, settings, edit, delete, leave.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Accounts, Messaging}

  def handle_event("select_conversation", %{"id" => conversation_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{conversation_id}")}
  end

  def handle_event("search_conversations", %{"value" => query}, socket) do
    filtered =
      if query == "" do
        socket.assigns.conversation.list
      else
        ElektrineWeb.ChatLive.Operations.Helpers.filter_conversations(
          socket.assigns.conversation.list,
          query,
          socket.assigns.current_user.id
        )
      end

    # Also search for users and public groups/channels when query is 2+ characters
    {user_results, public_group_results, public_channel_results} =
      if String.length(query) >= 2 do
        users = Accounts.search_users(query, socket.assigns.current_user.id)

        public_conversations =
          Messaging.search_public_conversations(query, socket.assigns.current_user.id)

        groups = Enum.filter(public_conversations, &(&1.type == "group"))
        channels = Enum.filter(public_conversations, &(&1.type == "channel"))
        {users, groups, channels}
      else
        {[], [], []}
      end

    {:noreply,
     socket
     |> assign(:conversation, %{socket.assigns.conversation | filtered: filtered})
     |> assign(:search, %{
       socket.assigns.search
       | conversation_query: query,
         user_results: user_results
     })
     |> assign(:public_group_search_results, public_group_results)
     |> assign(:public_channel_search_results, public_channel_results)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  def handle_event("pin_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    user_id = socket.assigns.current_user.id

    case Messaging.pin_conversation(conversation_id, user_id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, notify_error(socket, "Failed to pin conversation")}
    end
  end

  def handle_event("unpin_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    user_id = socket.assigns.current_user.id

    case Messaging.unpin_conversation(conversation_id, user_id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, notify_error(socket, "Failed to unpin conversation")}
    end
  end

  def handle_event("mark_as_read", %{"conversation_id" => conversation_id_str}, socket) do
    conversation_id = String.to_integer(conversation_id_str)
    user_id = socket.assigns.current_user.id

    case Messaging.mark_as_read(conversation_id, user_id) do
      {:ok, _} ->
        updated_unread_counts =
          Map.put(socket.assigns.conversation.unread_counts, conversation_id, 0)

        {:noreply,
         socket
         |> assign(:conversation, %{
           socket.assigns.conversation
           | unread_counts: updated_unread_counts,
             unread_count: Messaging.get_unread_count(user_id)
         })
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> assign(:first_unread_message_id, nil)
         |> notify_info("Marked as read")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> notify_error("You are not a member of this conversation")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> notify_error("Failed to mark as read")}
    end
  end

  def handle_event("clear_history", %{"conversation_id" => conversation_id_str}, socket) do
    conversation_id = String.to_integer(conversation_id_str)
    user_id = socket.assigns.current_user.id

    case Messaging.clear_history_for_user(conversation_id, user_id) do
      {:ok, :cleared} ->
        selected_conversation = socket.assigns.conversation.selected

        socket =
          if selected_conversation && selected_conversation.id == conversation_id do
            socket
            |> assign(:messages, [])
            |> assign(:oldest_message_id, nil)
            |> assign(:newest_message_id, nil)
            |> assign(:has_more_older_messages, false)
            |> assign(:has_more_newer_messages, false)
            |> assign(:first_unread_message_id, nil)
          else
            socket
          end

        Process.send_after(self(), :refresh_conversations, 50)

        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> notify_info("History cleared")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> notify_error("You are not a member of this conversation")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | conversation: nil})
         |> notify_error("Failed to clear history")}
    end
  end

  def handle_event("show_settings", _params, socket) do
    updated_ui = Map.put(socket.assigns.ui, :show_settings_modal, true)
    {:noreply, assign(socket, :ui, updated_ui)}
  end

  def handle_event("hide_settings", _params, socket) do
    updated_ui = Map.put(socket.assigns.ui, :show_settings_modal, false)
    {:noreply, assign(socket, :ui, updated_ui)}
  end

  def handle_event("show_edit_conversation", _params, socket) do
    updated_ui = Map.put(socket.assigns.ui, :show_edit_modal, true)
    {:noreply, assign(socket, :ui, updated_ui)}
  end

  def handle_event("hide_edit_conversation", _params, socket) do
    updated_ui = Map.put(socket.assigns.ui, :show_edit_modal, false)
    {:noreply, assign(socket, :ui, updated_ui)}
  end

  def handle_event("update_conversation", params, socket) do
    conversation = socket.assigns.conversation.selected

    case Messaging.update_conversation(conversation.id, %{
           name: params["name"],
           description: params["description"]
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_edit_modal, false))
         |> notify_info("Conversation updated")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to update conversation")}
    end
  end

  def handle_event("delete_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    conversation = Messaging.get_conversation!(conversation_id, socket.assigns.current_user.id)

    case Messaging.delete_conversation(conversation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/chat")
         |> notify_info("Conversation deleted")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to delete conversation")}
    end
  end

  def handle_event("leave_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    do_leave_conversation(conversation_id, socket)
  end

  def handle_event("leave_conversation", _params, socket) do
    # Handle case when triggered without conversation_id (use selected conversation)
    case socket.assigns.conversation.selected do
      nil ->
        {:noreply, notify_error(socket, "No conversation selected")}

      conversation ->
        do_leave_conversation(conversation.id, socket)
    end
  end

  def handle_event("view_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("share_conversation", _params, socket) do
    conversation = socket.assigns.conversation.selected
    share_url = "#{ElektrineWeb.Endpoint.url()}/chat/join/#{conversation.hash || conversation.id}"

    {:noreply,
     push_event(socket, "copy_to_clipboard", %{text: share_url, type: "conversation link"})}
  end

  def handle_event("show_conversation_info", _params, socket) do
    updated_ui = Map.put(socket.assigns.ui, :show_conversation_info, true)
    {:noreply, assign(socket, :ui, updated_ui)}
  end

  # Private helpers

  defp do_leave_conversation(conversation_id, socket) do
    user_id = socket.assigns.current_user.id

    case Messaging.leave_conversation(conversation_id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/chat")
         |> notify_info("Left conversation")}

      {:error, :owner_must_transfer} ->
        {:noreply, notify_error(socket, "Transfer ownership before leaving")}

      {:error, :not_a_member} ->
        {:noreply, notify_error(socket, "You are not a member of this conversation")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to leave conversation")}
    end
  end
end
