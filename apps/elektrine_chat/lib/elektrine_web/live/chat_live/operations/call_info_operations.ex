defmodule ElektrineWeb.ChatLive.Operations.CallInfoOperations do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]
  import ElektrineWeb.Live.NotificationHelpers, only: [notify_info: 2]

  @doc false
  def route_info(info, socket) do
    case info do
      {:incoming_call, call} -> {:handled, handle_incoming_call(socket, call)}
      {:call_rejected, call} -> {:handled, handle_call_rejected(socket, call)}
      {:call_ended, call} -> {:handled, handle_call_ended(socket, call)}
      {:call_missed, call} -> {:handled, handle_call_missed(socket, call)}
      _ -> :unhandled
    end
  end

  def handle_incoming_call(socket, call) do
    # Deduplicate - ignore if already showing this call
    if socket.assigns.call && socket.assigns.call.incoming_call &&
         socket.assigns.call.incoming_call.id == call.id do
      {:noreply, socket}
    else
      call =
        if local_call_with_loaded_users?(call) do
          call
        else
          maybe_reload_local_call(call)
        end

      socket =
        socket
        |> assign(:call, %{socket.assigns.call | incoming_call: call, status: "ringing"})
        |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, true))
        |> push_event("play_incoming_ringtone", %{})

      {:noreply, socket}
    end
  end

  def handle_call_rejected(socket, call),
    do: handle_call_terminal_event(socket, call, "call_rejected", "Call was rejected")

  def handle_call_ended(socket, call),
    do: handle_call_terminal_event(socket, call, "call_ended", "Call ended")

  def handle_call_missed(socket, call),
    do: handle_call_terminal_event(socket, call, "call_missed", "Call timed out")

  defp handle_call_terminal_event(socket, call, event_type, message) do
    event_key = {event_type, call.id}

    if MapSet.member?(socket.assigns.processed_call_events, event_key) do
      {:noreply, socket}
    else
      has_incoming =
        socket.assigns.call && socket.assigns.call.incoming_call &&
          socket.assigns.call.incoming_call.id == call.id

      has_active =
        socket.assigns.call && socket.assigns.call.active_call &&
          socket.assigns.call.active_call.id == call.id

      processed = MapSet.put(socket.assigns.processed_call_events, event_key)

      if has_incoming || has_active do
        cleared_call_state = reset_call_state(socket.assigns.call)

        socket =
          socket
          |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
          |> assign(:call, cleared_call_state)
          |> assign(:processed_call_events, processed)
          |> push_event("stop_ringtone", %{})
          |> notify_info(message)

        {:noreply, socket}
      else
        {:noreply, assign(socket, :processed_call_events, processed)}
      end
    end
  end

  defp reset_call_state(call_state) do
    call_state
    |> Map.put(:incoming_call, nil)
    |> Map.put(:active_call, nil)
    |> Map.put(:status, nil)
    |> Map.put(:audio_enabled, true)
    |> Map.put(:video_enabled, true)
  end

  defp local_call_with_loaded_users?(%{source: :federated}), do: true

  defp local_call_with_loaded_users?(call) do
    Ecto.assoc_loaded?(call.caller) and Ecto.assoc_loaded?(call.callee)
  end

  defp maybe_reload_local_call(%{source: :federated} = call), do: call

  defp maybe_reload_local_call(call) do
    Elektrine.Calls.get_call_with_users(call.id) || call
  end
end
