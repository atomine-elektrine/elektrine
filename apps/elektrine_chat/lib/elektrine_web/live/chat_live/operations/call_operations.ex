defmodule ElektrineWeb.ChatLive.Operations.CallOperations do
  @moduledoc "Handles voice/video call operations: initiate, answer, reject, end, audio/video toggle.\nExtracted from ChatLive.Home.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers
  alias Elektrine.Calls
  alias Elektrine.Calls.Transport, as: CallTransport
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.VoiceCalls
  alias ElektrineWeb.ChatLive.Operations.Helpers

  def handle_event(
        "initiate_call",
        %{"call_type" => call_type, "conversation_id" => conversation_id_str} = params,
        socket
      ) do
    case parse_optional_integer(conversation_id_str) do
      {:ok, conversation_id} ->
        case remote_call_target(params, conversation_id, socket) do
          {:remote, remote_handle, remote_conversation_id} ->
            initiate_federated_call(socket, remote_handle, remote_conversation_id, call_type)

          :local ->
            initiate_local_call(socket, params, conversation_id, call_type)

          {:error, :invalid_remote_handle} ->
            {:noreply, notify_error(socket, "Invalid remote call target")}
        end

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("answer_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        answer_call(socket, call_id)

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("reject_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        reject_call(socket, call_id)

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("end_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        end_call(socket, call_id)

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("toggle_audio", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_video", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("audio_toggled", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :call, %{socket.assigns.call | audio_enabled: truthy?(enabled)})}
  end

  def handle_event("video_toggled", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :call, %{socket.assigns.call | video_enabled: truthy?(enabled)})}
  end

  def handle_event("call_error", %{"error" => error}, socket) do
    maybe_fail_active_call(socket)

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})
     |> notify_error("Call error: #{error}")}
  end

  def handle_event("call_started", _params, socket) do
    {:noreply, assign(socket, :call, %{socket.assigns.call | status: "connecting"})}
  end

  def handle_event("remote_stream_ready", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("call_answered", _params, socket) do
    {:noreply, assign(socket, :call, %{socket.assigns.call | status: "connecting"})}
  end

  def handle_event("call_connected", _params, socket) do
    {:noreply, assign(socket, :call, %{socket.assigns.call | status: "connected"})}
  end

  def handle_event("call_ended", _params, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})}
  end

  def handle_event("call_ended_by_user", _params, socket) do
    maybe_end_active_call(socket)

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})}
  end

  def handle_event("call_rejected", _params, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})
     |> notify_info("Call was rejected")}
  end

  defp reset_call_state(call_state) do
    %{
      call_state
      | active_call: nil,
        incoming_call: nil,
        status: nil,
        audio_enabled: true,
        video_enabled: true
    }
  end

  defp initiate_local_call(socket, params, conversation_id, call_type) do
    case parse_integer(params["user_id"]) do
      {:ok, callee_id} ->
        caller_id = socket.assigns.current_user.id

        case VoiceCalls.local_user_busy_reason(caller_id) do
          :federated_call_active ->
            {:noreply, notify_error(socket, "You're already in another call")}

          _ ->
            case Calls.initiate_call(caller_id, callee_id, call_type, conversation_id) do
              {:ok, call} ->
                full_call = Calls.get_call_with_users(call.id) || call
                transport = call_transport(full_call.id, socket)

                Phoenix.PubSub.broadcast(
                  Elektrine.PubSub,
                  "user:#{full_call.callee_id}",
                  {:incoming_call, full_call}
                )

                {:noreply,
                 socket
                 |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
                 |> assign(:call, call_state_for(socket.assigns.call, full_call, "calling"))
                 |> push_event("start_call", %{
                   call_id: full_call.id,
                   call_type: full_call.call_type,
                   ice_servers: transport["ice_servers"],
                   transport: transport,
                   user_token: user_token(socket),
                   user_id: caller_id
                 })}

              {:error, :caller_already_in_call} ->
                {:noreply, notify_error(socket, "You're already in a call")}

              {:error, :callee_already_in_call} ->
                {:noreply, notify_error(socket, "This user is already in another call")}

              {:error, :rate_limit_exceeded} ->
                {:noreply,
                 notify_error(socket, "You're starting calls too quickly. Try again shortly.")}

              {:error, :invalid_conversation} ->
                {:noreply,
                 notify_error(socket, "Call can only be started from your shared DM conversation")}

              {:error, reason} ->
                error_msg = Elektrine.Privacy.privacy_error_message(reason)
                {:noreply, notify_error(socket, error_msg)}
            end
        end

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  defp initiate_federated_call(socket, _remote_handle, conversation_id, call_type)
       when is_integer(conversation_id) do
    caller_id = socket.assigns.current_user.id

    with {:ok, session} <-
           VoiceCalls.start_outbound_session(caller_id, conversation_id, call_type),
         :ok <- Federation.publish_dm_call_invite(session.id) do
      full_call = VoiceCalls.ui_call(session)
      transport = call_transport(full_call.id, socket)

      {:noreply,
       socket
       |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
       |> assign(:call, call_state_for(socket.assigns.call, full_call, "calling"))
       |> push_event("start_call", %{
         call_id: full_call.id,
         call_type: full_call.call_type,
         ice_servers: transport["ice_servers"],
         transport: transport,
         user_token: user_token(socket),
         user_id: caller_id
       })}
    else
      {:error, :remote_call_already_active} ->
        {:noreply, notify_error(socket, "You already have an active remote call in this DM")}

      {:error, :local_call_already_active} ->
        {:noreply, notify_error(socket, "You're already in another call")}

      {:error, :invalid_remote_call} ->
        {:noreply, notify_error(socket, "Call can only be started from a federated DM")}

      {:error, reason} ->
        {:noreply, notify_error(socket, "Failed to start remote call: #{format_reason(reason)}")}
    end
  end

  defp initiate_federated_call(socket, _remote_handle, _conversation_id, _call_type) do
    {:noreply, notify_error(socket, "Call can only be started from a federated DM")}
  end

  defp answer_call(socket, call_id) do
    case current_call_source(socket, call_id) do
      :federated ->
        case VoiceCalls.accept_session(call_id, socket.assigns.current_user.id) do
          {:ok, session} ->
            full_call = socket.assigns.call.incoming_call || VoiceCalls.ui_call(session)
            transport = call_transport(call_id, socket)

            {:noreply,
             socket
             |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
             |> assign(:call, call_state_for(socket.assigns.call, full_call, "connecting"))
             |> push_event("stop_ringtone", %{})
             |> push_event("answer_call", %{
               call_id: call_id,
               ice_servers: transport["ice_servers"],
               transport: transport,
               user_token: user_token(socket),
               user_id: socket.assigns.current_user.id
             })}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to answer call")}
        end

      _ ->
        case Calls.answer_call(call_id) do
          {:ok, call} ->
            full_call =
              socket.assigns.call.incoming_call || socket.assigns.call.active_call ||
                Calls.get_call_with_users(call.id)

            transport = call_transport(call_id, socket)

            {:noreply,
             socket
             |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
             |> assign(:call, call_state_for(socket.assigns.call, full_call, "connecting"))
             |> push_event("stop_ringtone", %{})
             |> push_event("answer_call", %{
               call_id: call_id,
               ice_servers: transport["ice_servers"],
               transport: transport,
               user_token: user_token(socket),
               user_id: socket.assigns.current_user.id
             })}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to answer call")}
        end
    end
  end

  defp reject_call(socket, call_id) do
    if current_call_source(socket, call_id) == :federated do
      _ = VoiceCalls.reject_session(call_id, socket.assigns.current_user.id)
    else
      _ = Calls.reject_call(call_id)
    end

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})
     |> push_event("reject_call", %{call_id: call_id, user_token: user_token(socket)})}
  end

  defp end_call(socket, call_id) do
    if current_call_source(socket, call_id) == :federated do
      _ = VoiceCalls.end_session(call_id, socket.assigns.current_user.id)
    else
      _ = Calls.end_call(call_id)
    end

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
     |> assign(:call, reset_call_state(socket.assigns.call))
     |> push_event("stop_ringtone", %{})}
  end

  defp call_state_for(current_call_state, call, status) do
    %{
      current_call_state
      | active_call: call,
        incoming_call: nil,
        status: status,
        audio_enabled: true,
        video_enabled: not is_nil(call) and call.call_type == "video"
    }
  end

  defp current_call_source(socket, call_id) do
    active_call = socket.assigns.call.active_call
    incoming_call = socket.assigns.call.incoming_call

    cond do
      is_map(active_call) and active_call.id == call_id ->
        active_call[:source] || :local

      is_map(incoming_call) and incoming_call.id == call_id ->
        incoming_call[:source] || :local

      match?(%{source: :federated}, active_call) or match?(%{source: :federated}, incoming_call) ->
        :federated

      true ->
        :local
    end
  end

  defp maybe_fail_active_call(socket) do
    case socket.assigns.call.active_call do
      %{source: :federated, id: session_id} ->
        _ = VoiceCalls.fail_session(session_id, socket.assigns.current_user.id)
        _ = Federation.publish_dm_call_end(session_id)

      %{id: call_id} ->
        _ = Calls.update_call_status(call_id, "failed")

      _ ->
        :ok
    end
  end

  defp maybe_end_active_call(socket) do
    case socket.assigns.call.active_call do
      %{source: :federated, id: session_id} ->
        _ = VoiceCalls.end_session(session_id, socket.assigns.current_user.id)

      %{id: call_id} ->
        _ = Calls.end_call(call_id)

      _ ->
        :ok
    end
  end

  defp remote_call_target(params, conversation_id, _socket) do
    remote_handle = normalize_remote_handle(params["remote_handle"])

    cond do
      is_binary(remote_handle) and is_integer(conversation_id) ->
        {:remote, remote_handle, conversation_id}

      is_binary(remote_handle) ->
        {:error, :invalid_remote_handle}

      true ->
        :local
    end
  end

  defp normalize_remote_handle(handle) when is_binary(handle) do
    case String.trim(handle) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_remote_handle(_handle), do: nil

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_reason), do: "unknown"

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(value) when is_integer(value) do
    {:ok, value}
  end

  defp parse_integer(_value) do
    {:error, :invalid_integer}
  end

  defp parse_optional_integer(nil) do
    {:ok, nil}
  end

  defp parse_optional_integer("") do
    {:ok, nil}
  end

  defp parse_optional_integer(value) do
    parse_integer(value)
  end

  defp truthy?(value) when value in [true, "true", 1, "1"] do
    true
  end

  defp truthy?(_value) do
    false
  end

  defp user_token(socket) do
    socket.assigns[:user_token] || Helpers.generate_user_token(socket.assigns.current_user.id)
  end

  defp call_transport(call_id, socket) when is_integer(call_id) do
    CallTransport.descriptor_for_user(socket.assigns.current_user.id, call_id)
  end
end
