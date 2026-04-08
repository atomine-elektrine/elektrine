defmodule ElektrineChatWeb.ChatLive.Operations.ConversationOperations do
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

  alias Elektrine.Accounts
  alias Elektrine.Messaging, as: Messaging

  def handle_event("select_conversation", %{"id" => conversation_id}, socket) do
    {:noreply, push_patch(socket, to: Elektrine.Paths.chat_path(conversation_id))}
  end

  def handle_event("search_conversations", %{"value" => query}, socket) do
    scoped_conversations =
      ElektrineChatWeb.ChatLive.Operations.Helpers.scope_conversations_to_server(
        socket.assigns.conversation.list,
        socket.assigns[:active_server_id]
      )

    filtered =
      if query == "" do
        scoped_conversations
      else
        ElektrineChatWeb.ChatLive.Operations.Helpers.filter_conversations(
          scoped_conversations,
          query,
          socket.assigns.current_user.id
        )
      end

    # Also search for users and public servers/groups when query is 2+ characters
    {user_results, public_server_results, public_group_results} =
      if String.length(query) >= 2 do
        users =
          query
          |> Accounts.search_users(socket.assigns.current_user.id)
          |> maybe_add_remote_handle_result(query)

        servers =
          Messaging.list_public_servers(socket.assigns.current_user.id, query: query, limit: 10)

        public_conversations =
          Messaging.search_public_conversations(query, socket.assigns.current_user.id)

        groups = Enum.filter(public_conversations, &(&1.type == "group"))
        {users, servers, groups}
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
     |> assign(:public_server_search_results, public_server_results)
     |> assign(:public_group_search_results, public_group_results)
     |> assign(:public_channel_search_results, [])}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, push_patch(socket, to: Elektrine.Paths.chat_root_path())}
  end

  def handle_event("pin_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    user_id = socket.assigns.current_user.id

    case Messaging.pin_conversation(conversation_id, user_id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, notify_error(socket, "Failed to pin chat")}
    end
  end

  def handle_event("unpin_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    user_id = socket.assigns.current_user.id

    case Messaging.unpin_conversation(conversation_id, user_id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, notify_error(socket, "Failed to unpin chat")}
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
         |> notify_error("You are not a member of this chat")}

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
         |> notify_error("You are not a member of this chat")}

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
    conversation_params = Map.get(params, "conversation", params)
    name = Map.get(conversation_params, "name", conversation.name)
    description = Map.get(conversation_params, "description", conversation.description)

    visibility_attrs =
      cond do
        conversation.type == "channel" and is_integer(conversation.server_id) ->
          is_private = parse_checkbox_value(Map.get(conversation_params, "is_private"))
          %{is_public: !is_private}

        conversation.type in ["channel", "group"] ->
          is_public = parse_checkbox_value(Map.get(conversation_params, "is_public"))
          %{is_public: is_public}

        true ->
          %{}
      end

    attrs =
      %{
        name: normalize_optional_text(name),
        description: normalize_optional_text(description)
      }
      |> Map.merge(visibility_attrs)

    case Messaging.update_conversation(conversation, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_edit_modal, false))
         |> notify_info("Chat updated")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to update chat")}
    end
  end

  def handle_event("delete_conversation", %{"conversation_id" => conversation_id}, socket) do
    conversation_id = String.to_integer(conversation_id)
    conversation = Messaging.get_conversation!(conversation_id, socket.assigns.current_user.id)

    case Messaging.delete_conversation(conversation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: Elektrine.Paths.chat_root_path())
         |> notify_info("Chat deleted")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to delete chat")}
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
        {:noreply, notify_error(socket, "No chat selected")}

      conversation ->
        do_leave_conversation(conversation.id, socket)
    end
  end

  def handle_event("view_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("share_conversation", _params, socket) do
    conversation = socket.assigns.conversation.selected

    share_url =
      ElektrineWeb.Endpoint.url() <>
        Elektrine.Paths.chat_join_path(conversation.hash || conversation.id)

    {:noreply,
     push_event(socket, "copy_to_clipboard", %{text: share_url, type: "chat invite link"})}
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
         |> push_patch(to: Elektrine.Paths.chat_root_path())
         |> notify_info("Left chat")}

      {:error, :owner_must_transfer} ->
        {:noreply, notify_error(socket, "Transfer ownership before leaving")}

      {:error, :not_a_member} ->
        {:noreply, notify_error(socket, "You are not a member of this chat")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to leave chat")}
    end
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

  defp normalize_optional_text(nil), do: nil

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(value), do: value

  defp parse_checkbox_value(value) when is_list(value) do
    Enum.any?(value, &parse_checkbox_value/1)
  end

  defp parse_checkbox_value(value) do
    value in [true, "true", "on", "1", 1]
  end
end
