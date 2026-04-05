defmodule ElektrineChatWeb.ChatLive.Operations.MemberOperations do
  @moduledoc """
  Handles member management: add, kick, promote, demote, timeout.
  Extracted from ChatLive.Home.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging, as: Messaging

  def handle_event("show_add_members", _params, socket) do
    pending_remote_join_requests =
      load_pending_remote_join_requests(
        socket.assigns.conversation.selected,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_add_members_modal, true))
     |> assign(:pending_remote_join_requests, pending_remote_join_requests)}
  end

  def handle_event("hide_add_members", _params, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_add_members_modal, false))
     |> assign(:pending_remote_join_requests, [])}
  end

  def handle_event("add_member_to_conversation", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.add_member_to_conversation(conversation.id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_add_members_modal, false))
         |> notify_info("Member added")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to add member")}
    end
  end

  def handle_event("approve_remote_join_request", %{"remote_actor_id" => remote_actor_id}, socket) do
    review_remote_join_request(socket, remote_actor_id, :approve)
  end

  def handle_event("decline_remote_join_request", %{"remote_actor_id" => remote_actor_id}, socket) do
    review_remote_join_request(socket, remote_actor_id, :decline)
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

    case Messaging.update_member_role(
           conversation.id,
           user_id,
           "admin",
           socket.assigns.current_user.id
         ) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "Member promoted to admin")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to promote member")}
    end
  end

  def handle_event("demote_member", %{"user_id" => user_id}, socket) do
    conversation = socket.assigns.conversation.selected
    user_id = String.to_integer(user_id)

    case Messaging.update_member_role(
           conversation.id,
           user_id,
           "member",
           socket.assigns.current_user.id
         ) do
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

  defp review_remote_join_request(socket, remote_actor_id, decision)
       when decision in [:approve, :decline] do
    conversation = socket.assigns.conversation.selected

    with true <- can_manage_remote_join_requests?(conversation, socket.assigns.current_user),
         {parsed_remote_actor_id, ""} <- Integer.parse(remote_actor_id) do
      result =
        case decision do
          :approve ->
            Messaging.approve_remote_join_request(
              conversation.id,
              parsed_remote_actor_id,
              socket.assigns.current_user.id
            )

          :decline ->
            Messaging.decline_remote_join_request(
              conversation.id,
              parsed_remote_actor_id,
              socket.assigns.current_user.id
            )
        end

      case result do
        {:ok, _request} ->
          updated_requests =
            load_pending_remote_join_requests(conversation, socket.assigns.current_user)

          message =
            if decision == :approve do
              "Remote join approved"
            else
              "Remote join declined"
            end

          {:noreply,
           socket
           |> assign(:pending_remote_join_requests, updated_requests)
           |> notify_info(message)}

        {:error, :not_found} ->
          {:noreply, notify_error(socket, "Remote join request not found")}

        {:error, _reason} ->
          {:noreply, notify_error(socket, "Failed to review remote join request")}
      end
    else
      false ->
        {:noreply, notify_error(socket, "You don't have permission to review remote joins")}

      _ ->
        {:noreply, notify_error(socket, "Invalid remote join request")}
    end
  end

  defp load_pending_remote_join_requests(
         %{type: "channel", is_federated_mirror: false, id: conversation_id} = conversation,
         current_user
       ) do
    if can_manage_remote_join_requests?(conversation, current_user) do
      Messaging.list_pending_remote_join_requests(conversation_id)
    else
      []
    end
  end

  defp load_pending_remote_join_requests(_conversation, _current_user), do: []

  defp can_manage_remote_join_requests?(conversation, current_user) do
    current_member =
      case conversation do
        %{members: members} when is_list(members) ->
          Enum.find(members, fn member ->
            member.user_id == Map.get(current_user, :id) and is_nil(member.left_at)
          end)

        _ ->
          nil
      end

    Map.get(current_user, :is_admin, false) or
      (!!current_member && current_member.role in ["owner", "admin", "moderator"])
  end
end
