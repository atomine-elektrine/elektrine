defmodule ElektrineWeb.Live.NotificationHelpers do
  @moduledoc """
  Helper functions for sending stackable notifications from LiveView.

  ## Stackable Flash System

  These helpers provide stackable notifications that can show multiple messages
  simultaneously, unlike Phoenix's `put_flash` which only allows one message per type.

  ### Use these helpers instead of `put_flash` when:
  - You need multiple notifications to stack
  - Messages should be repeatable without clearing
  - Real-time events from PubSub
  - Any LiveView that needs better notification UX

  ### For backwards compatibility:
  You can create wrapper functions that replace `put_flash`:
  ```elixir
  def notify_info(socket, message), do: notify_info(socket, message)
  def notify_error(socket, message), do: notify_error(socket, message)
  ```

  ## Options

  All notification functions accept an optional `opts` keyword list:
  - `:title` - Custom title (overrides default)
  - `:duration` - Auto-dismiss time in ms (default: 5000, use 0 for persistent)
  - `:persistent` - If true, notification won't auto-dismiss
  - `:progress` - If true, show a countdown progress bar
  - `:undo_event` - Event name for undo action (adds Undo button)
  - `:undo_data` - Data to pass with undo event
  - `:actions` - List of action button maps: %{label: "Label", event: "event_name", data: %{}}
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
  Sends a success notification via JavaScript.

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
  Sends an info notification via JavaScript.

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
  Sends an error notification via JavaScript.

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
  Sends a warning notification via JavaScript.

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
  Sends a loading notification via JavaScript.
  Loading notifications are persistent by default.

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
  Sends a custom notification via JavaScript.

  ## Examples

      socket |> notify("Custom message", "custom-type")
      socket |> notify("With options", "info", duration: 10000)
  """
  @spec notify(Phoenix.LiveView.Socket.t(), String.t(), String.t(), notify_opts()) ::
          Phoenix.LiveView.Socket.t()
  def notify(socket, message, type, opts \\ []) do
    push_notification(socket, message, type, opts)
  end

  # Private helper to build and push the notification event
  defp push_notification(socket, message, type, opts) do
    payload =
      %{message: message, type: type}
      |> maybe_add_opt(opts, :title)
      |> maybe_add_opt(opts, :duration)
      |> maybe_add_persistent(opts)
      |> maybe_add_opt(opts, :progress)
      |> maybe_add_opt(opts, :undo_event, :undoEvent)
      |> maybe_add_opt(opts, :undo_data, :undoData)
      |> maybe_add_actions(opts)

    Phoenix.LiveView.push_event(socket, "show_notification", payload)
  end

  defp maybe_add_opt(payload, opts, key, js_key \\ nil) do
    js_key = js_key || key

    case Keyword.get(opts, key) do
      nil -> payload
      value -> Map.put(payload, js_key, value)
    end
  end

  defp maybe_add_persistent(payload, opts) do
    case Keyword.get(opts, :persistent) do
      true -> Map.put(payload, :persistent, true)
      _ -> payload
    end
  end

  defp maybe_add_actions(payload, opts) do
    case Keyword.get(opts, :actions) do
      nil -> payload
      [] -> payload
      actions when is_list(actions) -> Map.put(payload, :actions, actions)
    end
  end

  @doc """
  Replacement for put_flash that supports stacking.
  Import this function to override Phoenix's put_flash in your LiveViews.

  ## Examples

      import ElektrineWeb.Live.NotificationHelpers, only: [put_stackable_flash: 3]

      socket |> put_stackable_flash(:info, "First message")
      socket |> put_stackable_flash(:info, "Second message")  # Both will show!
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
