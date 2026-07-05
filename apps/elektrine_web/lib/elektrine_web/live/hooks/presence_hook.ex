defmodule ElektrineWeb.Live.Hooks.PresenceHook do
  @moduledoc """
  LiveView hook to track and display user presence globally across the app.

  Tracks the current session as one device on the global presence topic and
  consumes aggregated `{:presence_changed, user_id, snapshot}` events from
  `ElektrineWeb.Presence` — it never sees raw per-device presence diffs.
  Multi-device aggregation, last-seen persistence on disconnect, and
  federation publishing all live in `ElektrineWeb.Presence.handle_metas/4`.

  Auto-away is driven by the `ActivityTracker` JS hook: it pushes
  `auto_away_timeout` after 5 idle minutes and `user_activity` with
  `clear_away` on the next interaction.
  """
  import Phoenix.LiveView
  import Phoenix.Component
  alias ElektrineWeb.Presence

  # Minimum interval between periodic last_seen database updates (5 minutes)
  @last_seen_update_interval_ms 5 * 60 * 1000

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
        socket =
          if connected?(socket) do
            Presence.subscribe_status_updates()
            # Personal channel for manual status changes and federation presence
            Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")

            Elektrine.Accounts.update_last_seen_async(user.id)

            Presence.track_user(self(), user, device_info_from_connect_params(socket))

            last_seen_ref =
              Process.send_after(self(), :update_last_seen, @last_seen_update_interval_ms)

            assign(socket, :last_seen_timer_ref, last_seen_ref)
          else
            assign(socket, :last_seen_timer_ref, nil)
          end

        socket =
          socket
          |> assign(:is_auto_away, false)
          |> assign(:user_statuses, initial_user_statuses(socket, user))
          |> then(&assign(&1, :online_users, online_user_ids(&1.assigns.user_statuses)))
          |> assign(:presence_hook_mounted, true)
          |> attach_hook(:presence_updater, :handle_info, &handle_presence_info/2)
          |> attach_hook(:presence_events, :handle_event, &handle_presence_event/3)

        {:cont, socket}
    end
  end

  defp initial_user_statuses(socket, user) do
    statuses = if connected?(socket), do: Presence.list_user_statuses(), else: %{}

    # Always include the current user immediately to avoid a flash of offline
    # state before our own join is aggregated.
    Map.put(statuses, to_string(user.id), %{
      status: user.status || "online",
      message: user.status_message,
      last_seen_at: user.last_seen_at && DateTime.to_unix(user.last_seen_at),
      devices: ["desktop"],
      device_count: 1
    })
  end

  defp device_info_from_connect_params(socket) do
    params = get_connect_params(socket) || %{}

    %{
      device_type: normalize_device_type(params["device_type"]),
      browser: params["browser"],
      timezone: params["timezone"]
    }
  end

  defp normalize_device_type(type) when type in ["desktop", "mobile", "tablet"], do: type
  defp normalize_device_type(_type), do: "desktop"

  defp handle_presence_info({:presence_changed, user_id, snapshot}, socket) do
    current_user = socket.assigns.current_user
    current_user_id = to_string(current_user.id)

    cond do
      # Another device of ours disconnected while this one is still here;
      # our own tracked meta keeps us present, so an offline snapshot for
      # ourselves can only be transient churn. Ignore it.
      user_id == current_user_id and snapshot.status == "offline" ->
        {:halt, socket}

      user_id == current_user_id ->
        old_status = current_user.status || "online"
        user_statuses = Map.put(socket.assigns.user_statuses, user_id, snapshot)

        socket =
          socket
          |> assign(:user_statuses, user_statuses)
          |> assign(:online_users, online_user_ids(user_statuses))

        # Status changed from another tab/device: sync assigns and selectors.
        socket =
          if snapshot.status != old_status do
            socket
            |> assign(:current_user, Map.put(current_user, :status, snapshot.status))
            |> push_event("status_updated", %{status: snapshot.status})
          else
            socket
          end

        {:halt, socket}

      true ->
        user_statuses = Map.put(socket.assigns.user_statuses, user_id, snapshot)

        socket =
          socket
          |> assign(:user_statuses, user_statuses)
          |> assign(:online_users, online_user_ids(user_statuses))

        {:halt, socket}
    end
  end

  defp handle_presence_info({:status_changed, new_status}, socket) do
    # User's own status changed manually (via settings/status selector).
    user = socket.assigns.current_user
    updated_user = Elektrine.Repo.get(Elektrine.Accounts.User, user.id) || user

    if connected?(socket) do
      Presence.update_user_meta(self(), user.id, %{
        status: new_status,
        status_message: updated_user.status_message,
        auto_away: false
      })
    end

    user_statuses =
      Map.update(
        socket.assigns.user_statuses,
        to_string(user.id),
        %{status: new_status, message: updated_user.status_message},
        fn existing ->
          Map.merge(existing, %{status: new_status, message: updated_user.status_message})
        end
      )

    # Only clear the manual flag when the user explicitly goes back online.
    socket =
      socket
      |> assign(:current_user, updated_user)
      |> assign(:user_statuses, user_statuses)
      |> assign(:is_auto_away, false)
      |> assign(:manual_status_set, new_status != "online")
      |> push_event("status_updated", %{status: new_status})

    {:halt, socket}
  end

  defp handle_presence_info({:federation_presence_update, _payload}, socket) do
    # Federation presence rides the personal topic; let chat views consume it
    # directly and swallow it elsewhere.
    if Map.has_key?(socket.assigns, :federation_presence) do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_presence_info(:update_last_seen, socket) do
    user = socket.assigns[:current_user]

    if user && connected?(socket) && !socket.assigns[:is_auto_away] do
      Elektrine.Accounts.update_last_seen_async(user.id)
    end

    ref = Process.send_after(self(), :update_last_seen, @last_seen_update_interval_ms)
    {:halt, assign(socket, :last_seen_timer_ref, ref)}
  end

  defp handle_presence_info(_message, socket) do
    {:cont, socket}
  end

  # The ActivityTracker JS hook reports activity only when there is something
  # to do server-side: clearing an auto-away.
  defp handle_presence_event("user_activity", params, socket) do
    user = socket.assigns[:current_user]

    clear? =
      params["clear_away"] && socket.assigns[:is_auto_away] &&
        socket.assigns[:manual_status_set] != true

    if user && connected?(socket) && clear? do
      Presence.update_user_meta(self(), user.id, %{status: "online", auto_away: false})

      {:halt,
       socket
       |> assign(:is_auto_away, false)
       |> update_own_status("online")
       |> push_event("auto_away_cleared", %{})}
    else
      {:halt, socket}
    end
  end

  defp handle_presence_event("auto_away_timeout", _params, socket) do
    user = socket.assigns[:current_user]

    # Only auto-away users who are plain "online" (not manually away/dnd).
    if user && connected?(socket) && !socket.assigns[:is_auto_away] &&
         (user.status || "online") == "online" do
      Presence.update_user_meta(self(), user.id, %{status: "away", auto_away: true})

      {:halt,
       socket
       |> assign(:is_auto_away, true)
       |> update_own_status("away")
       |> push_event("auto_away_set", %{was_auto: true})}
    else
      {:halt, socket}
    end
  end

  defp handle_presence_event("device_detected", _params, socket) do
    # Legacy event from older clients; device info now arrives in connect params.
    {:halt, socket}
  end

  defp handle_presence_event("connection_changed", _params, socket) do
    {:halt, socket}
  end

  defp handle_presence_event(_event, _params, socket) do
    {:cont, socket}
  end

  defp update_own_status(socket, status) do
    user_id = to_string(socket.assigns.current_user.id)

    user_statuses =
      Map.update(
        socket.assigns.user_statuses,
        user_id,
        %{status: status, message: nil, devices: [], device_count: 0},
        fn existing -> Map.merge(existing, %{status: status}) end
      )

    socket
    |> assign(:user_statuses, user_statuses)
    |> assign(:online_users, online_user_ids(user_statuses))
  end

  defp online_user_ids(user_statuses) do
    for {user_id, %{status: status}} <- user_statuses, status != "offline", do: user_id
  end
end
