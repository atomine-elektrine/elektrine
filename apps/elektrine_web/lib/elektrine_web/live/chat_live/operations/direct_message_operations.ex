defmodule ElektrineWeb.ChatLive.Operations.DirectMessageOperations do
  @moduledoc """
  Handles direct messaging: starting DMs, searching users, blocking.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Accounts, Messaging}

  def handle_event("start_dm", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Messaging.create_dm_conversation(socket.assigns.current_user.id, user_id) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, false))
         |> push_patch(to: ~p"/chat/#{conversation.id}")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to start conversation")}
    end
  end

  def handle_event("search_users", %{"value" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        Accounts.search_users(query, limit: 10)
      else
        []
      end

    {:noreply, assign(socket, :search, %{socket.assigns.search | query: query, results: results})}
  end

  def handle_event("block_user", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Accounts.block_user(socket.assigns.current_user.id, user_id) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "User blocked")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to block user")}
    end
  end

  def handle_event("unblock_user", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Accounts.unblock_user(socket.assigns.current_user.id, user_id) do
      {:ok, _} ->
        {:noreply, notify_info(socket, "User unblocked")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to unblock user")}
    end
  end

  def handle_event("show_user_profile", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user!(String.to_integer(user_id))
    # Preload profile for the modal
    user_with_profile = Elektrine.Repo.preload(user, :profile)

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_profile_modal, true))
     |> assign(:profile_user, user_with_profile)}
  end

  def handle_event("hide_profile_modal", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_profile_modal, false))}
  end
end
