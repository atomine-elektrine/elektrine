defmodule ElektrineWeb.Live.Hooks.PresenceEvents do
  @moduledoc """
  Event handlers for presence-related JS hooks.

  Import this module in your LiveView to handle events from:
  - ActivityTracker (user_activity, auto_away_timeout)
  - DeviceDetector (device_detected, connection_changed)

  ## Usage

      defmodule MyAppWeb.SomeLive do
        use MyAppWeb, :live_view
        import ElektrineWeb.Live.Hooks.PresenceEvents

        # Add to your handle_event clauses:
        def handle_event("user_activity", params, socket) do
          handle_presence_event("user_activity", params, socket)
        end

        def handle_event("auto_away_timeout", params, socket) do
          handle_presence_event("auto_away_timeout", params, socket)
        end

        def handle_event("device_detected", params, socket) do
          handle_presence_event("device_detected", params, socket)
        end
      end

  Or use the `__using__` macro for automatic inclusion.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  @doc """
  Handle presence-related events from JS hooks.
  Returns {:noreply, socket} for all events.
  """
  def handle_presence_event("user_activity", params, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) do
      # Update last activity time
      socket = assign(socket, :last_activity_at, System.system_time(:second))

      # Only clear away if it was auto-set, not manually set
      # Check both is_auto_away flag AND that user hasn't manually set status
      is_auto_away = socket.assigns[:is_auto_away] == true
      is_manual_status = socket.assigns[:manual_status_set] == true

      if params["clear_away"] && is_auto_away && !is_manual_status do
        socket = clear_auto_away(socket, user)
        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_presence_event("auto_away_timeout", _params, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) && !socket.assigns[:is_auto_away] do
      # Only auto-away if user is currently "online"
      current_status = user.status || "online"

      if current_status == "online" do
        socket = set_auto_away(socket, user)
        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_presence_event("device_detected", params, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) do
      device_type = params["device_type"] || "desktop"
      browser = params["browser"]

      # Update presence metadata with device info
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{
          device_type: device_type,
          browser: browser
        })
      end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_presence_event("connection_changed", params, socket) do
    # Could be used to track connection quality
    # Currently this event is accepted without additional processing.
    _connection_type = params["type"]
    {:noreply, socket}
  end

  def handle_presence_event(_event, _params, socket) do
    {:noreply, socket}
  end

  # Set user to auto-away status
  defp set_auto_away(socket, user) do
    # Update presence metadata
    ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
      Map.merge(meta, %{status: "away", auto_away: true})
    end)

    # Update user_statuses
    current_statuses = current_user_statuses(socket)

    user_statuses =
      Map.update(
        current_statuses,
        to_string(user.id),
        %{status: "away", message: nil, devices: [], device_count: 0},
        fn existing -> Map.merge(existing, %{status: "away"}) end
      )

    socket
    |> assign(:is_auto_away, true)
    |> assign(:user_statuses, user_statuses)
    |> push_event("auto_away_set", %{was_auto: true})
  end

  # Clear auto-away when user becomes active
  # Only clears if status was auto-set, not manually set
  defp clear_auto_away(socket, user) do
    # Double-check this was auto-away, not manual
    if socket.assigns[:is_auto_away] == true && socket.assigns[:manual_status_set] != true do
      # Update presence metadata
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{
          status: "online",
          auto_away: false,
          last_activity_at: System.system_time(:second)
        })
      end)

      # Update user_statuses
      current_statuses = current_user_statuses(socket)

      user_statuses =
        Map.update(
          current_statuses,
          to_string(user.id),
          %{status: "online", message: nil, devices: [], device_count: 0},
          fn existing -> Map.merge(existing, %{status: "online"}) end
        )

      socket
      |> assign(:is_auto_away, false)
      |> assign(:last_activity_at, System.system_time(:second))
      |> assign(:user_statuses, user_statuses)
      |> push_event("auto_away_cleared", %{})
    else
      # Manual status set, don't clear
      assign(socket, :last_activity_at, System.system_time(:second))
    end
  end

  defp current_user_statuses(socket) do
    case socket.assigns[:user_statuses] do
      statuses when is_map(statuses) -> statuses
      _ -> %{}
    end
  end

  @doc """
  Macro to automatically add presence event handlers to a LiveView.
  """
  defmacro __using__(_opts) do
    quote do
      def handle_event("user_activity", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "user_activity",
          params,
          socket
        )
      end

      def handle_event("auto_away_timeout", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "auto_away_timeout",
          params,
          socket
        )
      end

      def handle_event("device_detected", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "device_detected",
          params,
          socket
        )
      end

      def handle_event("connection_changed", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "connection_changed",
          params,
          socket
        )
      end
    end
  end
end
