defmodule ElektrineWeb.ChatLive.Operations.GroupChannelOperations do
  @moduledoc """
  Handles group and channel creation, browsing, and joining.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging, as: Messaging

  def handle_event("toggle_new_chat", _params, socket) do
    {:noreply,
     assign(
       socket,
       :ui,
       Map.put(socket.assigns.ui, :show_new_chat, !socket.assigns.ui.show_new_chat)
     )}
  end

  def handle_event("show_create_group", _params, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, true))
     |> assign(:form, %{socket.assigns.form | selected_users: []})
     |> assign(:search, %{socket.assigns.search | query: "", results: []})}
  end

  def handle_event("show_create_channel", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_channel_modal, true))}
  end

  def handle_event("create_group", params, socket) do
    name = params["name"]
    selected_users = socket.assigns.form.selected_users

    if String.trim(name) == "" || Enum.empty?(selected_users) do
      {:noreply, notify_error(socket, "Please enter a name and select at least one user")}
    else
      case Messaging.create_group_conversation(
             socket.assigns.current_user.id,
             %{name: name},
             selected_users
           ) do
        {:ok, conversation} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, false))
           |> push_patch(to: ~p"/chat/#{conversation.id}")
           |> notify_info("Group created!")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create group")}
      end
    end
  end

  def handle_event("create_channel", params, socket) do
    name = params["name"]
    is_public = params["is_public"] == "true"

    if String.trim(name) == "" do
      {:noreply, notify_error(socket, "Please enter a channel name")}
    else
      attrs = %{name: name, is_public: is_public}

      case Messaging.create_channel(socket.assigns.current_user.id, attrs) do
        {:ok, conversation} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_channel_modal, false))
           |> push_patch(to: ~p"/chat/#{conversation.id}")
           |> notify_info("Channel created!")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create channel")}
      end
    end
  end

  def handle_event("cancel_create", _params, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_group_modal, false)
      |> Map.put(:show_channel_modal, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)
     |> assign(:form, %{socket.assigns.form | selected_users: []})}
  end

  def handle_event("toggle_user_selection", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    selected = socket.assigns.form.selected_users

    updated =
      if user_id in selected do
        List.delete(selected, user_id)
      else
        [user_id | selected]
      end

    {:noreply, assign(socket, :form, %{socket.assigns.form | selected_users: updated})}
  end

  def handle_event("show_browse_modal", _params, socket) do
    public_channels = Messaging.list_public_channels()
    public_groups = Messaging.list_public_groups()

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_browse_modal, true))
     |> assign(:search, %{socket.assigns.search | browse_query: ""})
     |> assign(:browse, %{
       socket.assigns.browse
       | tab: "channels",
         public_channels: public_channels,
         public_groups: public_groups,
         filtered_channels: public_channels,
         filtered_groups: public_groups
     })}
  end

  def handle_event("hide_browse_modal", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_browse_modal, false))}
  end

  def handle_event("browse_tab", %{"tab" => tab}, socket) do
    updated_browse = %{socket.assigns.browse | tab: tab}
    {:noreply, assign(socket, :browse, updated_browse)}
  end

  def handle_event("browse_search", %{"search" => query}, socket) do
    query = String.trim(query) |> String.downcase()

    # Filter channels and groups based on query (filter from original lists)
    filtered_channels =
      if query == "" do
        socket.assigns.browse.public_channels
      else
        Enum.filter(socket.assigns.browse.public_channels, fn c ->
          String.contains?(String.downcase(c.name || ""), query) ||
            String.contains?(String.downcase(c.description || ""), query)
        end)
      end

    filtered_groups =
      if query == "" do
        socket.assigns.browse.public_groups
      else
        Enum.filter(socket.assigns.browse.public_groups, fn g ->
          String.contains?(String.downcase(g.name || ""), query) ||
            String.contains?(String.downcase(g.description || ""), query)
        end)
      end

    {:noreply,
     socket
     |> assign(:search, %{socket.assigns.search | browse_query: query})
     |> assign(:browse, %{
       socket.assigns.browse
       | filtered_channels: filtered_channels,
         filtered_groups: filtered_groups
     })}
  end

  def handle_event("join_conversation", %{"conversation_id" => conversation_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/join/#{conversation_id}")}
  end

  def handle_event("join_group", %{"group_id" => group_id}, socket) do
    conversation_id = String.to_integer(group_id)

    case Messaging.join_conversation(conversation_id, socket.assigns.current_user.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/chat/#{conversation_id}")
         |> notify_info("Joined group")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to join group")}
    end
  end

  def handle_event("join_channel", %{"channel_id" => channel_id}, socket) do
    conversation_id = String.to_integer(channel_id)

    case Messaging.join_conversation(conversation_id, socket.assigns.current_user.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/chat/#{conversation_id}")
         |> notify_info("Joined channel")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to join channel")}
    end
  end
end
