defmodule ElektrineUptimeWeb.UptimeLive.Index do
  use ElektrineUptimeWeb, :live_view

  alias Elektrine.Uptime
  alias Elektrine.Uptime.Monitor

  @uptime_window_days 90
  @latency_samples 100

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user do
      {:ok,
       socket
       |> assign(:page_title, "Uptime")
       |> assign(:check_types, Monitor.check_types())
       |> assign(:monitors, Uptime.list_monitors(user))
       |> assign(:active_monitor, nil)
       |> assign(:editing_monitor_id, nil)
       |> assign(:check_type, "http")
       |> assign(:uptime_series, [])
       |> assign(:latency_series, [])
       |> assign(:uptime_percentage, nil)
       |> assign(:recent_checks, [])
       |> assign(:incidents, [])
       |> assign_new_monitor_form()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access Uptime")
       |> redirect(to: Elektrine.Paths.login_path())}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    monitors = Uptime.list_monitors(user)
    active = resolve_active_monitor(monitors, params["monitor_id"], user)

    socket =
      socket
      |> maybe_resubscribe(active)
      |> assign(:monitors, monitors)
      |> assign(:active_monitor, active)
      |> load_detail(active)

    {:noreply, socket}
  end

  @impl true
  def handle_event("monitor_validate", %{"monitor" => params}, socket) do
    changeset =
      editing_monitor(socket)
      |> Uptime.change_monitor(params_with_user(socket, params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:check_type, form_check_type(params, socket))
     |> assign(:monitor_form, to_form(changeset, as: :monitor))}
  end

  @impl true
  def handle_event("monitor_save", %{"monitor" => params}, socket) do
    case socket.assigns.editing_monitor_id do
      nil -> create_monitor(socket, params)
      id -> update_existing_monitor(socket, id, params)
    end
  end

  @impl true
  def handle_event("edit_monitor", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {monitor_id, ""} <- Integer.parse(to_string(id)),
         %Monitor{} = monitor <- Uptime.get_monitor(monitor_id, user.id) do
      {:noreply,
       socket
       |> assign(:editing_monitor_id, monitor.id)
       |> assign(:check_type, monitor.check_type)
       |> assign(:monitor_form, to_form(Uptime.change_monitor(monitor), as: :monitor))}
    else
      _ -> {:noreply, notify_error(socket, "Could not load monitor for editing.")}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_monitor_id, nil)
     |> assign(:check_type, "http")
     |> assign_new_monitor_form()}
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {monitor_id, ""} <- Integer.parse(to_string(id)),
         %Monitor{} = monitor <- Uptime.get_monitor(monitor_id, user.id),
         {:ok, updated} <- Uptime.update_monitor(monitor, %{"enabled" => !monitor.enabled}) do
      {:noreply,
       socket
       |> notify_info(if(updated.enabled, do: "Monitor enabled.", else: "Monitor paused."))
       |> assign(:monitors, Uptime.list_monitors(user))
       |> maybe_update_active(updated)}
    else
      _ -> {:noreply, notify_error(socket, "Could not update monitor.")}
    end
  end

  @impl true
  def handle_event("delete_monitor", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {monitor_id, ""} <- Integer.parse(to_string(id)),
         %Monitor{} = monitor <- Uptime.get_monitor(monitor_id, user.id),
         {:ok, _} <- Uptime.delete_monitor(monitor) do
      {:noreply,
       socket
       |> notify_info("Monitor deleted.")
       |> push_patch(to: ~p"/uptime")}
    else
      _ -> {:noreply, notify_error(socket, "Could not delete monitor.")}
    end
  end

  @impl true
  def handle_info({:uptime_check, monitor, check}, socket) do
    socket = assign(socket, :monitors, replace_monitor(socket.assigns.monitors, monitor))

    socket =
      case socket.assigns.active_monitor do
        %Monitor{id: id} when id == monitor.id ->
          socket
          |> assign(:active_monitor, monitor)
          |> assign(:recent_checks, [check | socket.assigns.recent_checks] |> Enum.take(50))
          |> assign(:uptime_series, Uptime.daily_uptime_series(monitor.id, @uptime_window_days))
          |> assign(:latency_series, Uptime.latency_series(monitor.id, @latency_samples))
          |> assign(:uptime_percentage, Uptime.uptime_percentage(monitor.id, @uptime_window_days))
          |> assign(:incidents, Uptime.list_incidents(monitor.id))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Detail loading + PubSub

  defp resolve_active_monitor(monitors, nil, _user), do: maybe_first(monitors)

  defp resolve_active_monitor(monitors, monitor_id, user) do
    case Integer.parse(to_string(monitor_id)) do
      {id, ""} ->
        Enum.find(monitors, &(&1.id == id)) || Uptime.get_monitor(id, user.id) ||
          maybe_first(monitors)

      _ ->
        maybe_first(monitors)
    end
  end

  defp maybe_first([monitor | _]), do: monitor
  defp maybe_first(_), do: nil

  defp load_detail(socket, %Monitor{} = monitor) do
    socket
    |> assign(:uptime_series, Uptime.daily_uptime_series(monitor.id, @uptime_window_days))
    |> assign(:latency_series, Uptime.latency_series(monitor.id, @latency_samples))
    |> assign(:uptime_percentage, Uptime.uptime_percentage(monitor.id, @uptime_window_days))
    |> assign(:recent_checks, Uptime.recent_checks(monitor.id))
    |> assign(:incidents, Uptime.list_incidents(monitor.id))
  end

  defp load_detail(socket, _), do: socket

  defp maybe_resubscribe(socket, active) do
    previous = socket.assigns[:active_monitor]
    previous_id = previous && previous.id
    active_id = active && active.id

    if connected?(socket) and previous_id != active_id do
      if previous_id, do: Phoenix.PubSub.unsubscribe(Elektrine.PubSub, topic(previous_id))
      if active_id, do: Phoenix.PubSub.subscribe(Elektrine.PubSub, topic(active_id))
    end

    socket
  end

  defp topic(monitor_id), do: "uptime:monitor:#{monitor_id}"

  ## Save helpers

  defp create_monitor(socket, params) do
    case Uptime.create_monitor(socket.assigns.current_user, params) do
      {:ok, monitor} ->
        {:noreply,
         socket
         |> notify_info("Monitor created.")
         |> push_patch(to: ~p"/uptime?monitor_id=#{monitor.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> notify_error("Could not create monitor.")
         |> assign(:monitor_form, to_form(%{changeset | action: :insert}, as: :monitor))}
    end
  end

  defp update_existing_monitor(socket, id, params) do
    user = socket.assigns.current_user

    with {monitor_id, ""} <- Integer.parse(to_string(id)),
         %Monitor{} = monitor <- Uptime.get_monitor(monitor_id, user.id) do
      case Uptime.update_monitor(monitor, params) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:editing_monitor_id, nil)
           |> notify_info("Monitor updated.")
           |> push_patch(to: ~p"/uptime?monitor_id=#{updated.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> notify_error("Could not update monitor.")
           |> assign(:monitor_form, to_form(%{changeset | action: :update}, as: :monitor))}
      end
    else
      _ -> {:noreply, notify_error(socket, "Could not update monitor.")}
    end
  end

  ## Assign helpers

  defp assign_new_monitor_form(socket) do
    changeset = Uptime.new_monitor_changeset(socket.assigns.current_user)
    assign(socket, :monitor_form, to_form(changeset, as: :monitor))
  end

  defp editing_monitor(socket) do
    case socket.assigns.editing_monitor_id do
      nil ->
        %Monitor{}

      id ->
        Uptime.get_monitor(id, socket.assigns.current_user.id) || %Monitor{}
    end
  end

  defp params_with_user(socket, params),
    do: Map.put(params, "user_id", socket.assigns.current_user.id)

  defp form_check_type(%{"check_type" => type}, _socket) when type in ["http", "tcp", "ping"],
    do: type

  defp form_check_type(_params, socket), do: socket.assigns.check_type

  defp replace_monitor(monitors, %Monitor{id: id} = updated) do
    Enum.map(monitors, fn
      %Monitor{id: ^id} -> updated
      other -> other
    end)
  end

  defp maybe_update_active(socket, %Monitor{id: id} = updated) do
    case socket.assigns.active_monitor do
      %Monitor{id: ^id} -> assign(socket, :active_monitor, updated)
      _ -> socket
    end
  end

  ## View helpers

  defp status_label(%Monitor{enabled: false}), do: "Paused"
  defp status_label(%Monitor{last_status: "up"}), do: "Up"
  defp status_label(%Monitor{last_status: "down"}), do: "Down"
  defp status_label(_), do: "Pending"

  defp status_badge_class(%Monitor{enabled: false}), do: "badge badge-ghost badge-sm"
  defp status_badge_class(%Monitor{last_status: "up"}), do: "badge badge-success badge-sm"
  defp status_badge_class(%Monitor{last_status: "down"}), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-outline badge-sm"

  defp check_status_badge_class("up"), do: "badge badge-success badge-xs"
  defp check_status_badge_class("down"), do: "badge badge-error badge-xs"
  defp check_status_badge_class(_), do: "badge badge-outline badge-xs"

  defp latency_label(%Monitor{} = monitor) do
    case List.last(Uptime.latency_series(monitor.id, 1)) do
      %{response_time_ms: ms} when is_integer(ms) -> "#{ms} ms"
      _ -> "—"
    end
  end

  defp uptime_label(nil), do: "—"
  defp uptime_label(percentage), do: "#{:erlang.float_to_binary(percentage, decimals: 2)}%"

  defp target_label("http"), do: "URL"
  defp target_label(_), do: "Host"

  defp monitor_link_class(monitor, active) do
    base =
      "flex items-center justify-between gap-3 border-b border-base-content/10 px-5 py-3 transition hover:bg-base-200/40"

    if active && active.id == monitor.id do
      [base, "bg-base-200/60"]
    else
      base
    end
  end

  defp format_at(nil), do: "—"
  defp format_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_at(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
