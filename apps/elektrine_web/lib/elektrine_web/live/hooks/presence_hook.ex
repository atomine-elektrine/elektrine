defmodule ElektrineWeb.Live.Hooks.PresenceHook do
  @moduledoc """
  LiveView hook to track and display user presence globally across the app.

  Features:
  - Global presence tracking across all LiveViews
  - Auto-away detection (sets user to "away" after 5 minutes of inactivity)
  - Multi-device tracking (shows device type: desktop, mobile, tablet)
  - Optimized last_seen updates (batched, throttled)
  """
  import Phoenix.LiveView
  import Phoenix.Component

  # Auto-away timeout in milliseconds (5 minutes) - must match JS
  @auto_away_timeout_ms 5 * 60 * 1000

  # Minimum interval between last_seen database updates (2 minutes)
  @last_seen_update_interval_ms 2 * 60 * 1000

  def on_mount(:default, _params, _session, socket) do
    # Skip if already mounted (idempotent)
    if socket.assigns[:presence_hook_mounted] do
      {:cont, socket}
    else
      do_mount(socket)
    end
  end

  defp do_mount(socket) do
    case socket.assigns[:current_user] do
      nil ->
        socket =
          socket
          |> assign(:online_users, [])
          |> assign(:user_statuses, %{})
          |> assign(:presence_hook_mounted, true)

        {:cont, socket}

      user ->
        if connected?(socket) do
          # Subscribe to global presence updates
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "users")
          # Subscribe to personal channel for status updates
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")

          # Update last_seen_at timestamp via Accounts context
          Elektrine.Accounts.update_last_seen(user.id)

          # Track this user's presence globally (use string ID for consistency)
          tracked_status = user.status || "online"

          # Generate a unique connection ID for multi-device tracking
          connection_id = generate_connection_id()

          ElektrineWeb.Presence.track(self(), "users", to_string(user.id), %{
            user_id: user.id,
            username: user.username,
            status: tracked_status,
            status_message: user.status_message,
            online_at: System.system_time(:second),
            last_seen_at:
              (user.last_seen_at && DateTime.to_unix(user.last_seen_at)) ||
                System.system_time(:second),
            # Multi-device tracking
            connection_id: connection_id,
            device_type: "desktop",
            browser: nil,
            # Auto-away tracking
            auto_away: false,
            last_activity_at: System.system_time(:second)
          })

          # Start auto-away timer
          auto_away_ref = Process.send_after(self(), :check_auto_away, @auto_away_timeout_ms)
          # Schedule periodic last_seen update
          last_seen_ref =
            Process.send_after(self(), :update_last_seen, @last_seen_update_interval_ms)

          socket
          |> assign(:auto_away_timer_ref, auto_away_ref)
          |> assign(:last_seen_timer_ref, last_seen_ref)
          |> assign(:connection_id, connection_id)
          |> assign(:last_activity_at, System.system_time(:second))
          |> assign(:is_auto_away, false)
        else
          socket
          |> assign(:auto_away_timer_ref, nil)
          |> assign(:last_seen_timer_ref, nil)
          |> assign(:connection_id, nil)
          |> assign(:last_activity_at, nil)
          |> assign(:is_auto_away, false)
        end

        is_connected = connected?(socket)

        # Get initial user statuses map (user_id => %{status, message, devices})
        # Always include current user immediately to avoid flash of offline state
        user_statuses =
          if is_connected do
            presence_map =
              ElektrineWeb.Presence.list("users")
              |> build_aggregated_user_statuses()

            # Ensure current user is in the map with their preferred status
            current_status = user.status || "online"

            Map.put(presence_map, to_string(user.id), %{
              status: current_status,
              message: user.status_message,
              last_seen_at: user.last_seen_at && DateTime.to_unix(user.last_seen_at),
              devices: ["desktop"],
              device_count: 1
            })
          else
            # Even before connected, show current user as online
            %{
              to_string(user.id) => %{
                status: user.status || "online",
                message: user.status_message,
                last_seen_at: user.last_seen_at && DateTime.to_unix(user.last_seen_at),
                devices: [],
                device_count: 0
              }
            }
          end

        # Also maintain simple list for backward compatibility
        online_users = Map.keys(user_statuses)

        socket =
          socket
          |> assign(:user_statuses, user_statuses)
          |> assign(:online_users, online_users)
          |> assign(:presence_hook_mounted, true)
          |> attach_hook(:presence_updater, :handle_info, &handle_presence_info/2)
          |> attach_hook(:presence_events, :handle_event, &handle_presence_event/3)

        {:cont, socket}
    end
  end

  defp handle_presence_info(
         %Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff},
         socket
       ) do
    # Update user statuses based on presence diff
    user_statuses = socket.assigns.user_statuses
    current_user_id = to_string(socket.assigns.current_user.id)

    # When users leave presence (disconnect), mark them as offline but keep them in the map
    # Save last_seen timestamp and update database
    user_statuses =
      Enum.reduce(diff.leaves, user_statuses, fn {user_id, meta_data}, acc ->
        # IMPORTANT: Don't mark the current user as offline when they disconnect
        # This prevents the UI from showing "offline" during brief reconnections
        if to_string(user_id) == current_user_id do
          acc
        else
          # Get last_seen from presence meta or use current time
          last_seen =
            case meta_data do
              %{metas: [meta | _]} -> Map.get(meta, :last_seen_at, System.system_time(:second))
              _ -> System.system_time(:second)
            end

          # Update database with last_seen timestamp via Accounts context (async)
          db_user_id = if is_binary(user_id), do: String.to_integer(user_id), else: user_id
          Elektrine.Accounts.update_last_seen_async(db_user_id)

          # Keep user in map but update to offline status with last_seen
          Map.update(
            acc,
            to_string(user_id),
            %{status: "offline", message: nil, last_seen_at: last_seen},
            fn existing ->
              Map.merge(existing, %{status: "offline", last_seen_at: last_seen})
            end
          )
        end
      end)

    # Add/update users who joined with their status (aggregate multiple devices)
    new_statuses =
      diff.joins
      |> Enum.map(fn {user_id, %{metas: metas}} ->
        # Aggregate device info from all metas
        devices =
          metas
          |> Enum.map(fn meta -> meta[:device_type] || "desktop" end)
          |> Enum.uniq()

        # Use best status across devices
        status =
          metas
          |> Enum.map(fn meta -> meta[:status] || "online" end)
          |> Enum.min_by(&status_priority/1)

        message = Enum.find_value(metas, fn meta -> meta[:status_message] end)

        last_seen =
          metas
          |> Enum.map(fn meta -> meta[:last_seen_at] || meta[:online_at] end)
          |> Enum.max(fn -> System.system_time(:second) end)

        {to_string(user_id),
         %{
           status: status,
           message: message,
           last_seen_at: last_seen,
           devices: devices,
           device_count: length(metas)
         }}
      end)
      |> Map.new()

    user_statuses = Map.merge(user_statuses, new_statuses)

    # IMPORTANT: Ensure current user always has their actual status
    # This prevents race conditions where presence diff shows user leaving before joining
    current_user_status = socket.assigns.current_user.status || "online"

    # Check if current user's status changed in this diff
    old_current_status = get_in(socket.assigns.user_statuses, [current_user_id, :status])
    status_changed = old_current_status && old_current_status != current_user_status

    # Get current user's existing device info
    existing_current = Map.get(user_statuses, current_user_id, %{devices: [], device_count: 0})

    user_statuses =
      Map.put(user_statuses, current_user_id, %{
        status: current_user_status,
        message: socket.assigns.current_user.status_message,
        last_seen_at:
          socket.assigns.current_user.last_seen_at &&
            DateTime.to_unix(socket.assigns.current_user.last_seen_at),
        devices: existing_current[:devices] || [],
        device_count: existing_current[:device_count] || 1
      })

    # For online_users list, only include users who are actually connected (not offline)
    online_users =
      user_statuses
      |> Enum.filter(fn {_user_id, status_data} -> status_data.status != "offline" end)
      |> Enum.map(fn {user_id, _} -> user_id end)

    socket =
      socket
      |> assign(:user_statuses, user_statuses)
      |> assign(:online_users, online_users)

    # If current user's status changed in this diff, update current_user assign and push event
    socket =
      if status_changed do
        # Update current_user assign so navbar re-renders
        updated_current_user = Map.put(socket.assigns.current_user, :status, current_user_status)

        socket
        |> assign(:current_user, updated_current_user)
        |> push_event("status_updated", %{status: current_user_status})
      else
        socket
      end

    {:halt, socket}
  end

  defp handle_presence_info({:status_changed, new_status}, socket) do
    # User's own status changed (manually), update everything
    user = socket.assigns.current_user

    # Reload user from database to get updated status
    updated_user = Elektrine.Repo.get(Elektrine.Accounts.User, user.id)

    if connected?(socket) do
      # Update presence with new status - mark as manually set, not auto-away
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{status: new_status, auto_away: false})
      end)
    end

    # Update local assigns
    user_statuses =
      Map.put(socket.assigns.user_statuses, to_string(user.id), %{
        status: new_status,
        message: updated_user.status_message
      })

    # Track that this was a manual status change
    # Only clear manual flag when user explicitly sets to "online"
    manual_status_set = new_status != "online"

    socket =
      socket
      |> assign(:current_user, updated_user)
      |> assign(:user_statuses, user_statuses)
      |> assign(:is_auto_away, false)
      |> assign(:manual_status_set, manual_status_set)

    # Push event to both status selectors (desktop and mobile)
    socket =
      socket
      |> push_event("status_updated", %{status: new_status})

    {:halt, socket}
  end

  defp handle_presence_info({:user_status_updated, user_id, new_status}, socket) do
    # Another user's status changed, update their status in our map
    user_statuses =
      Map.update(
        socket.assigns.user_statuses,
        to_string(user_id),
        %{status: new_status, message: nil},
        fn existing -> %{existing | status: new_status} end
      )

    {:halt, assign(socket, :user_statuses, user_statuses)}
  end

  # Handle auto-away timeout check
  defp handle_presence_info(:check_auto_away, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) && !socket.assigns[:is_auto_away] do
      # Check if user has been inactive
      last_activity = socket.assigns[:last_activity_at] || System.system_time(:second)
      now = System.system_time(:second)
      inactive_seconds = now - last_activity

      # 5 minutes in seconds
      if inactive_seconds >= 300 do
        # Set auto-away
        socket = set_auto_away(socket, user)
        # Schedule next check
        ref = Process.send_after(self(), :check_auto_away, @auto_away_timeout_ms)
        {:halt, assign(socket, :auto_away_timer_ref, ref)}
      else
        # Not yet inactive, check again later
        remaining_ms = (300 - inactive_seconds) * 1000
        ref = Process.send_after(self(), :check_auto_away, max(remaining_ms, 10_000))
        {:halt, assign(socket, :auto_away_timer_ref, ref)}
      end
    else
      # Reschedule check
      ref = Process.send_after(self(), :check_auto_away, @auto_away_timeout_ms)
      {:halt, assign(socket, :auto_away_timer_ref, ref)}
    end
  end

  # Handle periodic last_seen update
  defp handle_presence_info(:update_last_seen, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) && !socket.assigns[:is_auto_away] do
      # Update last_seen in database (async to not block)
      Elektrine.Accounts.update_last_seen_async(user.id)
    end

    # Schedule next update
    ref = Process.send_after(self(), :update_last_seen, @last_seen_update_interval_ms)
    {:halt, assign(socket, :last_seen_timer_ref, ref)}
  end

  defp handle_presence_info(_message, socket) do
    # Pass through other messages
    {:cont, socket}
  end

  # Handle presence-related events from JavaScript hooks
  defp handle_presence_event("device_detected", params, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) do
      # Update presence with device info
      device_type = params["device_type"] || "desktop"
      browser = params["browser"]
      timezone = params["timezone"]

      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{
          device_type: device_type,
          browser: browser,
          timezone: timezone
        })
      end)

      # Update socket assigns if timezone provided
      socket =
        if timezone do
          assign(socket, :timezone, timezone)
        else
          socket
        end

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_presence_event("user_activity", _params, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) do
      now = System.system_time(:second)

      # Update last activity timestamp
      socket = assign(socket, :last_activity_at, now)

      # Clear auto-away if user was auto-away
      socket =
        if socket.assigns[:is_auto_away] do
          clear_auto_away(socket, user)
        else
          socket
        end

      # Update presence with activity timestamp
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{last_activity_at: now})
      end)

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_presence_event(_event, _params, socket) do
    # Pass through other events to the LiveView
    {:cont, socket}
  end

  # Set user to auto-away status
  defp set_auto_away(socket, user) do
    # Only set auto-away if user is currently "online" (not manually set to DND or away)
    current_status = user.status || "online"

    if current_status == "online" do
      # Update presence metadata
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{status: "away", auto_away: true})
      end)

      # Update user_statuses
      user_statuses =
        Map.update(
          socket.assigns.user_statuses,
          to_string(user.id),
          %{status: "away", message: nil, devices: [], device_count: 0},
          fn existing -> Map.merge(existing, %{status: "away"}) end
        )

      socket
      |> assign(:is_auto_away, true)
      |> assign(:user_statuses, user_statuses)
      |> push_event("auto_away_set", %{was_auto: true})
    else
      socket
    end
  end

  # Clear auto-away when user becomes active
  defp clear_auto_away(socket, user) do
    if socket.assigns[:is_auto_away] do
      # Update presence metadata
      ElektrineWeb.Presence.update(self(), "users", to_string(user.id), fn meta ->
        Map.merge(meta, %{
          status: "online",
          auto_away: false,
          last_activity_at: System.system_time(:second)
        })
      end)

      # Update user_statuses
      user_statuses =
        Map.update(
          socket.assigns.user_statuses,
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
      assign(socket, :last_activity_at, System.system_time(:second))
    end
  end

  # Build aggregated user statuses from presence data (handles multi-device)
  defp build_aggregated_user_statuses(presence_list) do
    presence_list
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      # Aggregate all devices for this user
      devices =
        metas
        |> Enum.map(fn meta -> meta[:device_type] || "desktop" end)
        |> Enum.uniq()

      # Use the "best" status (online > away > dnd > offline)
      # If any device is online, user is online
      status =
        metas
        |> Enum.map(fn meta -> meta[:status] || "online" end)
        |> Enum.min_by(&status_priority/1)

      # Get message from first meta that has one
      message =
        metas
        |> Enum.find_value(fn meta -> meta[:status_message] end)

      # Get most recent last_seen
      last_seen =
        metas
        |> Enum.map(fn meta -> meta[:last_seen_at] || meta[:online_at] end)
        |> Enum.max(fn -> System.system_time(:second) end)

      {to_string(user_id),
       %{
         status: status,
         message: message,
         last_seen_at: last_seen,
         devices: devices,
         device_count: length(metas)
       }}
    end)
    |> Map.new()
  end

  # Status priority (lower = more "present")
  defp status_priority("online"), do: 1
  defp status_priority("away"), do: 2
  defp status_priority("dnd"), do: 3
  defp status_priority("offline"), do: 4
  defp status_priority(_), do: 5

  # Generate unique connection ID for multi-device tracking
  defp generate_connection_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
