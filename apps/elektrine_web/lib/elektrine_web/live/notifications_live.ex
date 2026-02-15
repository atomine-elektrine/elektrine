defmodule ElektrineWeb.NotificationsLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Notifications
  import ElektrineWeb.Components.User.Avatar

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Load cached unread count to prevent badge flicker on refresh
    {:ok, cached_unread} =
      Elektrine.AppCache.get_notification_unread_count(user.id, fn ->
        Notifications.get_unread_count(user.id)
      end)

    if connected?(socket) do
      # Subscribe to notification updates
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:notifications")
      # Load notifications asynchronously after connection
      send(self(), :load_notifications)
    end

    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> assign(:loading_notifications, true)
     # Initialize with cached unread count to prevent flicker
     |> assign(:grouped_notifications, [])
     |> assign(:expanded_groups, MapSet.new())
     |> assign(:unread_count, cached_unread)
     |> assign(:unseen_count, 0)
     |> assign(:filter, :all)
     |> assign(:loading_more, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter =
      case params["filter"] do
        "unread" -> :unread
        "unseen" -> :unseen
        _ -> :all
      end

    socket = assign(socket, :filter, filter)

    # Only load data synchronously if we're connected and not in initial loading state
    # The initial load is handled by send(self(), :load_notifications) in mount
    if connected?(socket) && !socket.assigns.loading_notifications do
      grouped_notifications =
        Notifications.list_grouped_notifications(socket.assigns.current_user.id, filter: filter)

      {:noreply, assign(socket, :grouped_notifications, grouped_notifications)}
    else
      # Trigger async load for filter change when connected
      if connected?(socket) do
        send(self(), :load_notifications)
      end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("mark_as_read", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    # Refresh groups
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> update(:unread_count, &max(&1 - 1, 0))}
  end

  def handle_event("mark_visible_as_read", %{"notification_ids" => notification_ids}, socket) do
    # Mark only the visible notifications as read
    user_id = socket.assigns.current_user.id

    Enum.each(notification_ids, fn id ->
      Notifications.mark_as_read(String.to_integer(id), user_id)
    end)

    # Refresh groups
    grouped_notifications =
      Notifications.list_grouped_notifications(user_id, filter: socket.assigns.filter)

    unread_count = Notifications.get_unread_count(user_id)

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, unread_count)}
  end

  def handle_event("mark_all_as_read", _params, socket) do
    Notifications.mark_all_as_read(socket.assigns.current_user.id)

    # Refresh groups
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, 0)}
  end

  def handle_event("dismiss", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.dismiss_notification(notification_id, socket.assigns.current_user.id)

    # Refresh groups
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> update(:unread_count, &max(&1 - 1, 0))}
  end

  def handle_event("dismiss_all", _params, socket) do
    Notifications.dismiss_all_notifications(socket.assigns.current_user.id)

    # Refresh groups (should be empty now)
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, 0)}
  end

  def handle_event("filter", %{"type" => filter_type}, socket) do
    {:noreply, push_patch(socket, to: ~p"/notifications?filter=#{filter_type}")}
  end

  def handle_event("toggle_group", %{"group_key" => group_key}, socket) do
    expanded_groups = socket.assigns.expanded_groups

    new_expanded =
      if MapSet.member?(expanded_groups, group_key) do
        MapSet.delete(expanded_groups, group_key)
      else
        MapSet.put(expanded_groups, group_key)
      end

    {:noreply, assign(socket, :expanded_groups, new_expanded)}
  end

  def handle_event("mark_group_as_read", %{"group_index" => group_index_str}, socket) do
    group_index = String.to_integer(group_index_str)
    group = Enum.at(socket.assigns.grouped_notifications, group_index)

    if group do
      user_id = socket.assigns.current_user.id

      notification_ids =
        case group.type do
          type when type in [:chat_group, :email_group] ->
            Enum.map(group.notifications, & &1.id)

          :single ->
            [group.notification.id]
        end

      # Mark all as read
      Enum.each(notification_ids, fn id ->
        Notifications.mark_as_read(id, user_id)
      end)

      # Refresh
      grouped_notifications =
        Notifications.list_grouped_notifications(user_id, filter: socket.assigns.filter)

      unread_count = Notifications.get_unread_count(user_id)

      {:noreply,
       socket
       |> assign(:grouped_notifications, grouped_notifications)
       |> assign(:unread_count, unread_count)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_notification", %{"id" => notification_id, "url" => url}, socket) do
    # Mark as read when clicking on a notification
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    {:noreply,
     socket
     |> update(:unread_count, &max(&1 - 1, 0))
     |> push_navigate(to: url)}
  end

  @impl true
  def handle_info(:load_notifications, socket) do
    user = socket.assigns.current_user
    filter = socket.assigns.filter

    # Load notifications data in parallel
    notifications_task =
      Task.async(fn ->
        Notifications.list_grouped_notifications(user.id, filter: filter)
      end)

    unread_task = Task.async(fn -> Notifications.get_unread_count(user.id) end)
    unseen_task = Task.async(fn -> Notifications.get_unseen_count(user.id) end)

    grouped_notifications = Task.await(notifications_task)
    unread_count = Task.await(unread_task)
    unseen_count = Task.await(unseen_task)

    {:noreply,
     socket
     |> assign(:loading_notifications, false)
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, unread_count)
     |> assign(:unseen_count, unseen_count)}
  end

  @impl true
  def handle_info({:new_notification, _notification}, socket) do
    # Refresh groups when new notification arrives
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> update(:unread_count, &(&1 + 1))
     |> update(:unseen_count, &(&1 + 1))}
  end

  def handle_info(:notification_updated, socket) do
    # Refresh the entire notification list to show updated read status
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    # Refresh counts
    unread_count = Notifications.get_unread_count(socket.assigns.current_user.id)
    unseen_count = Notifications.get_unseen_count(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, unread_count)
     |> assign(:unseen_count, unseen_count)}
  end

  def handle_info(:all_notifications_read, socket) do
    # Refresh groups
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, 0)
     |> assign(:unseen_count, 0)}
  end

  def handle_info(:all_notifications_dismissed, socket) do
    # Refresh groups (should be empty now)
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, 0)
     |> assign(:unseen_count, 0)}
  end

  def handle_info(:notification_dismissed, socket) do
    # Refresh groups when a notification is dismissed
    grouped_notifications =
      Notifications.list_grouped_notifications(
        socket.assigns.current_user.id,
        filter: socket.assigns.filter
      )

    unread_count = Notifications.get_unread_count(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:grouped_notifications, grouped_notifications)
     |> assign(:unread_count, unread_count)}
  end

  def handle_info(:notifications_seen, socket) do
    # Handle notifications being marked as seen
    unseen_count = Notifications.get_unseen_count(socket.assigns.current_user.id)
    {:noreply, assign(socket, :unseen_count, unseen_count)}
  end

  def handle_info(_message, socket) do
    # Ignore other messages we don't handle
    {:noreply, socket}
  end

  # Helper functions
  defp notification_icon(type) do
    case type do
      "new_message" -> "hero-chat-bubble-left"
      "mention" -> "hero-at-symbol"
      "reply" -> "hero-chat-bubble-left-right"
      "follow" -> "hero-user-plus"
      "like" -> "hero-heart"
      "comment" -> "hero-chat-bubble-bottom-center"
      "discussion_reply" -> "hero-chat-bubble-bottom-center-text"
      "email_received" -> "hero-envelope"
      "system" -> "hero-information-circle"
      _ -> "hero-bell"
    end
  end

  defp notification_color(priority) do
    case priority do
      "urgent" -> "text-error"
      "high" -> "text-warning"
      "low" -> "text-base-content/60"
      _ -> "text-base-content"
    end
  end
end
