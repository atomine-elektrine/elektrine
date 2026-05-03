defmodule ElektrineWeb.Live.Hooks.NotificationCountHook do
  @moduledoc """
  LiveView hook to load notification count for the current user and subscribe to updates.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Elektrine.Platform.ENav

  def on_mount(:default, _params, _session, socket) do
    # Skip if already mounted (idempotent)
    if socket.assigns[:notification_count_hook_mounted] do
      {:cont, socket}
    else
      case socket.assigns[:current_user] do
        nil ->
          {:cont, assign(socket, :notification_count_hook_mounted, true)}

        user ->
          # Subscribe to notification updates
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:notifications")
            Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:notification_count")
          end

          count = Elektrine.Notifications.get_unread_count(user.id)

          socket =
            socket
            |> assign(:notification_count, count)
            |> assign(:e_nav_badge_counts, ENav.notification_badge_counts(user))
            |> assign(:notification_count_hook_mounted, true)
            |> attach_hook(:notification_count_updater, :handle_info, &handle_notification_info/2)

          {:cont, socket}
      end
    end
  end

  defp handle_notification_info({:new_notification, notification}, socket) do
    # Increment notification count
    new_count = (socket.assigns[:notification_count] || 0) + 1

    socket =
      socket
      |> assign(:notification_count, new_count)
      |> refresh_e_nav_badge_counts()
      |> push_event("show_notification", notification_payload(notification))

    {:cont, socket}
  end

  defp handle_notification_info({:notification_read, _notification_id}, socket) do
    # Decrement notification count
    new_count = max((socket.assigns[:notification_count] || 0) - 1, 0)

    {:cont,
     socket
     |> assign(:notification_count, new_count)
     |> refresh_e_nav_badge_counts()}
  end

  defp handle_notification_info({:all_notifications_read, _}, socket) do
    # Reset notification count
    {:cont,
     socket
     |> assign(:notification_count, 0)
     |> refresh_e_nav_badge_counts()}
  end

  defp handle_notification_info({:notification_count_updated, new_count}, socket) do
    # Update notification count directly from broadcast
    {:cont,
     socket
     |> assign(:notification_count, new_count)
     |> refresh_e_nav_badge_counts()}
  end

  defp handle_notification_info(:all_notifications_read, socket) do
    {:cont,
     socket
     |> assign(:notification_count, 0)
     |> refresh_e_nav_badge_counts()}
  end

  defp handle_notification_info(:notification_updated, socket) do
    count = Elektrine.Notifications.get_unread_count(socket.assigns.current_user.id)

    {:cont,
     socket
     |> assign(:notification_count, count)
     |> refresh_e_nav_badge_counts()}
  end

  defp handle_notification_info({:unread_count_updated, _new_count}, socket) do
    {:cont, refresh_e_nav_badge_counts(socket)}
  end

  defp handle_notification_info({:chat_unread_count_updated, _new_count}, socket) do
    {:halt, refresh_e_nav_badge_counts(socket)}
  end

  defp handle_notification_info({:email_unread_count_updated, _new_count}, socket) do
    {:halt, refresh_e_nav_badge_counts(socket)}
  end

  defp handle_notification_info({:friend_requests_updated, _new_count}, socket) do
    {:halt, refresh_e_nav_badge_counts(socket)}
  end

  defp handle_notification_info({:storage_updated, _storage_info}, socket) do
    {:cont, refresh_e_nav_badge_counts(socket)}
  end

  defp handle_notification_info(_message, socket) do
    # Pass through other messages
    {:cont, socket}
  end

  defp refresh_e_nav_badge_counts(%{assigns: %{current_user: current_user}} = socket)
       when not is_nil(current_user) do
    assign(socket, :e_nav_badge_counts, ENav.notification_badge_counts(current_user))
  end

  defp refresh_e_nav_badge_counts(socket), do: socket

  defp notification_payload(notification) do
    %{
      title: notification.title || "New notification",
      message: notification.body || notification.title || "You have a new notification",
      type: notification_toast_type(notification),
      duration: notification_duration(notification)
    }
  end

  defp notification_toast_type(%{priority: priority}) when priority in ["high", "urgent"],
    do: "warning"

  defp notification_toast_type(_notification), do: "info"

  defp notification_duration(%{priority: "urgent"}), do: 10_000
  defp notification_duration(_notification), do: 6_000
end
