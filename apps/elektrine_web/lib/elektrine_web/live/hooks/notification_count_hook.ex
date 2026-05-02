defmodule ElektrineWeb.Live.Hooks.NotificationCountHook do
  @moduledoc """
  LiveView hook to load notification count for the current user and subscribe to updates.
  """
  import Phoenix.LiveView
  import Phoenix.Component

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
      |> push_event("show_notification", notification_payload(notification))

    {:cont, socket}
  end

  defp handle_notification_info({:notification_read, _notification_id}, socket) do
    # Decrement notification count
    new_count = max((socket.assigns[:notification_count] || 0) - 1, 0)
    {:cont, assign(socket, :notification_count, new_count)}
  end

  defp handle_notification_info({:all_notifications_read, _}, socket) do
    # Reset notification count
    {:cont, assign(socket, :notification_count, 0)}
  end

  defp handle_notification_info({:notification_count_updated, new_count}, socket) do
    # Update notification count directly from broadcast
    {:cont, assign(socket, :notification_count, new_count)}
  end

  defp handle_notification_info(_message, socket) do
    # Pass through other messages
    {:cont, socket}
  end

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
