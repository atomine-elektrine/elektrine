defmodule ElektrineWeb.Live.NotificationHelpers do
  @moduledoc """
  Helper wrappers around LiveView `put_flash/3`.

  These functions preserve the existing `notify_*` API used across the codebase
  while routing all server notifications through standard Phoenix flash storage.

  ## Options

  The following options are supported:
  - `:title` - Custom title (overrides default)
  Additional options are accepted for compatibility but are ignored by Phoenix flash.
  """

  @type notify_opts :: [
          title: String.t(),
          duration: non_neg_integer() | :persistent,
          persistent: boolean(),
          progress: boolean(),
          undo_event: String.t(),
          undo_data: map(),
          actions: [map()]
        ]

  @doc """
  Sends a success notification via flash.

  ## Examples

      socket |> notify_success("User created successfully!")
      socket |> notify_success("Email sent!", title: "Done!")
      socket |> notify_success("Item deleted", undo_event: "undo_delete", undo_data: %{id: 123})
  """
  @spec notify_success(Phoenix.LiveView.Socket.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify_success(socket, message, opts \\ []) do
    push_notification(socket, message, "success", opts)
  end

  @doc """
  Sends an info notification via flash.

  ## Examples

      socket |> notify_info("Settings updated")
      socket |> notify_info("Processing your request...", persistent: true)
      socket |> notify_info("Changes saved", duration: 3000)
  """
  @spec notify_info(Phoenix.LiveView.Socket.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify_info(socket, message, opts \\ []) do
    push_notification(socket, message, "info", opts)
  end

  @doc """
  Sends an error notification via flash.

  ## Examples

      socket |> notify_error("User not found")
      socket |> notify_error("Invalid email address", title: "Validation Error")
      socket |> notify_error("Connection lost", persistent: true)
  """
  @spec notify_error(Phoenix.LiveView.Socket.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify_error(socket, message, opts \\ []) do
    push_notification(socket, message, "error", opts)
  end

  @doc """
  Sends a warning notification via flash.

  ## Examples

      socket |> notify_warning("Rate limit approaching")
      socket |> notify_warning("This action cannot be undone", progress: true)
  """
  @spec notify_warning(Phoenix.LiveView.Socket.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify_warning(socket, message, opts \\ []) do
    push_notification(socket, message, "warning", opts)
  end

  @doc """
  Sends a loading-style notification via flash.

  ## Examples

      socket |> notify_loading("Processing...")
      socket |> notify_loading("Uploading file...", title: "Please wait")
  """
  @spec notify_loading(Phoenix.LiveView.Socket.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify_loading(socket, message, opts \\ []) do
    # Loading notifications are persistent by default
    opts = Keyword.put_new(opts, :persistent, true)
    push_notification(socket, message, "loading", opts)
  end

  @doc """
  Sends a notification with an undo action.
  Useful for destructive actions that can be reversed.

  ## Examples

      socket |> notify_with_undo("Message deleted", "undo_delete_message", %{id: msg_id})
      socket |> notify_with_undo("User blocked", "undo_block", %{user_id: id}, type: :warning)
  """
  @spec notify_with_undo(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          map(),
          notify_opts()
        ) :: Phoenix.LiveView.Socket.t()
  def notify_with_undo(socket, message, undo_event, undo_data \\ %{}, opts \\ []) do
    type = Keyword.get(opts, :type, "info")
    # Use longer duration for undo notifications
    opts =
      opts
      |> Keyword.put_new(:duration, 8000)
      |> Keyword.put(:undo_event, undo_event)
      |> Keyword.put(:undo_data, undo_data)

    push_notification(socket, message, to_string(type), opts)
  end

  @doc """
  Sends a notification with custom action buttons.

  ## Examples

      socket |> notify_with_actions("New message received", [
        %{label: "View", event: "view_message", data: %{id: 123}},
        %{label: "Dismiss", event: "dismiss_notification"}
      ])
  """
  @spec notify_with_actions(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          [map()],
          notify_opts()
        ) :: Phoenix.LiveView.Socket.t()
  def notify_with_actions(socket, message, actions, opts \\ []) do
    type = Keyword.get(opts, :type, "info")
    opts = Keyword.put(opts, :actions, actions)
    push_notification(socket, message, to_string(type), opts)
  end

  @doc """
  Sends a custom notification via flash.

  ## Examples

      socket |> notify("Custom message", "custom-type")
      socket |> notify("With options", "info", duration: 10000)
  """
  @spec notify(Phoenix.LiveView.Socket.t(), String.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify(socket, message, type, opts \\ []) do
    push_notification(socket, message, type, opts)
  end

  # Private helper to store a normalized flash message.
  defp push_notification(socket, message, type, opts) do
    message = format_notification_message(message, Keyword.get(opts, :title))
    Phoenix.LiveView.put_flash(socket, notification_flash_kind(type), message)
  end

  defp format_notification_message(message, nil), do: message

  defp format_notification_message(message, title) when is_binary(title) do
    title = String.trim(title)
    if title == "", do: message, else: "#{title}: #{message}"
  end

  defp format_notification_message(message, _title), do: message

  defp notification_flash_kind(kind) do
    case to_string(kind) do
      "error" -> :error
      "warning" -> :error
      "info" -> :info
      "success" -> :info
      "loading" -> :info
      _ -> :info
    end
  end

  @doc """
  Compatibility wrapper that delegates to flash-based notifications.

  ## Examples

      import ElektrineWeb.Live.NotificationHelpers, only: [put_stackable_flash: 3]

      socket |> put_stackable_flash(:info, "Saved")
  """
  def put_stackable_flash(socket, :info, message) do
    notify_info(socket, message)
  end

  def put_stackable_flash(socket, :error, message) do
    notify_error(socket, message)
  end

  def put_stackable_flash(socket, :success, message) do
    notify_success(socket, message)
  end

  def put_stackable_flash(socket, :warning, message) do
    notify_warning(socket, message)
  end

  def put_stackable_flash(socket, _type, message) do
    notify_info(socket, message)
  end

  @doc """
  Handles notification count update messages and pushes events to JavaScript.
  Used for real-time notification bell updates.
  """
  def handle_notification_count_update({:notification_count_updated, new_count}, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(:notification_count, new_count)
     |> Phoenix.LiveView.push_event("phx:notification_count_updated", %{count: new_count})}
  end

  def handle_notification_count_update(:all_notifications_read, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(:notification_count, 0)
     |> Phoenix.LiveView.push_event("phx:notification_count_updated", %{count: 0})}
  end

  def handle_notification_count_update(:notification_updated, socket) do
    # Refresh count when individual notification is updated
    if socket.assigns[:current_user] do
      count = Elektrine.Notifications.get_unread_count(socket.assigns.current_user.id)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:notification_count, count)
       |> Phoenix.LiveView.push_event("phx:notification_count_updated", %{count: count})}
    else
      {:noreply, socket}
    end
  end

  def handle_notification_count_update(_msg, socket) do
    {:noreply, socket}
  end
end
