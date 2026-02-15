defmodule ElektrineWeb.ChatLive.Operations.MemberOperations do
  @moduledoc """
  Handles member management: add, kick, promote, demote, timeout.
  Extracted from ChatLive.Home.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging

  def handle_event("show_add_members", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_add_members, true))}
  end

  def handle_event("hide_add_members", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_add_members, false))}
  end

  def handle_event("add_member_to_conversation", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.add_member_to_conversation(conversation.id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_add_members, false))
         |> notify_info("Member added")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to add member")}
    end
  end

  def handle_event("kick_member", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.remove_member_from_conversation(conversation.id, user_id) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "Member removed")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to remove member")}
    end
  end

  def handle_event("promote_member", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.update_member_role(conversation.id, user_id, "admin") do
      {:ok, _} ->
        {:noreply, notify_info(socket, "Member promoted to admin")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to promote member")}
    end
  end

  def handle_event("demote_member", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.update_member_role(conversation.id, user_id, "member") do
      {:ok, _} ->
        {:noreply, notify_info(socket, "Member demoted")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to demote member")}
    end
  end

  def handle_event("timeout_user", params, socket) do
    user_id = String.to_integer(params["user_id"])
    duration = String.to_integer(params["duration"])
    conversation_id = socket.assigns.conversation.selected.id

    case Messaging.timeout_user(
           conversation_id,
           user_id,
           socket.assigns.current_user.id,
           duration
         ) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "User timed out")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to timeout user")}
    end
  end

  def handle_event("remove_timeout_user", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    conversation_id = socket.assigns.conversation.selected.id

    case Messaging.remove_timeout(conversation_id, user_id) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "Timeout removed")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to remove timeout")}
    end
  end

  def handle_event("kick_user", %{"user_id" => user_id}, socket) do
    handle_event("kick_member", %{"user_id" => user_id}, socket)
  end

  def handle_event("show_member_management", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_member_management, true))}
  end

  def handle_event("hide_member_management", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_member_management, false))}
  end

  def handle_event("show_moderation_log", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_moderation_log, true))}
  end

  def handle_event("hide_moderation_log", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_moderation_log, false))}
  end
end
