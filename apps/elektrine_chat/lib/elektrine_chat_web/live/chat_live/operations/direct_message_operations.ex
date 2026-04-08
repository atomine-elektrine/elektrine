defmodule ElektrineChatWeb.ChatLive.Operations.DirectMessageOperations do
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

  alias Elektrine.Accounts
  alias Elektrine.Messaging, as: Messaging

  def handle_event("start_dm", %{"remote_handle" => remote_handle}, socket)
      when is_binary(remote_handle) and remote_handle != "" do
    current_user_id = socket.assigns.current_user.id

    case Messaging.create_remote_dm_conversation(current_user_id, remote_handle) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, false))
         |> push_patch(to: Elektrine.Paths.chat_path(conversation))}

      {:error, :invalid_remote_handle} ->
        {:noreply, notify_error(socket, "Use handle format user@domain")}

      {:error, :unknown_peer} ->
        {:noreply,
         notify_error(
           socket,
           "That domain could not be reached through federation discovery"
         )}

      {:error, :rate_limited} ->
        {:noreply, notify_error(socket, "You are creating chats too quickly")}

      {:error, _reason} ->
        {:noreply, notify_error(socket, "Failed to start chat")}
    end
  end

  def handle_event("start_dm", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Messaging.create_dm_conversation(socket.assigns.current_user.id, user_id) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, false))
         |> push_patch(to: Elektrine.Paths.chat_path(conversation))}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to start chat")}
    end
  end

  def handle_event("search_users", %{"value" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        query
        |> Accounts.search_users(socket.assigns.current_user.id)
        |> maybe_add_remote_handle_result(query)
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

  defp maybe_add_remote_handle_result(results, query)
       when is_list(results) and is_binary(query) do
    case normalize_remote_handle(query) do
      {:ok, remote_handle} ->
        already_present? =
          Enum.any?(results, fn user ->
            user_handle = Map.get(user, :handle) || Map.get(user, "handle")
            String.downcase(to_string(user_handle || "")) == remote_handle
          end)

        if already_present? do
          results
        else
          [remote_search_result(remote_handle) | results]
        end

      :error ->
        results
    end
  end

  defp maybe_add_remote_handle_result(results, _query), do: results

  defp normalize_remote_handle(handle) when is_binary(handle) do
    normalized =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    case Regex.run(~r/^([a-z0-9_]{1,64})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] -> {:ok, "#{username}@#{domain}"}
      _ -> :error
    end
  end

  defp normalize_remote_handle(_), do: :error

  defp remote_search_result(remote_handle) do
    [username, _domain] = String.split(remote_handle, "@", parts: 2)

    %{
      id: nil,
      username: username,
      handle: remote_handle,
      display_name: "@#{remote_handle}",
      avatar: nil,
      remote_handle: remote_handle
    }
  end
end
