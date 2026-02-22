defmodule ElektrineWeb.ChatLive.Operations.CallOperations do
  @moduledoc "Handles voice/video call operations: initiate, answer, reject, end, audio/video toggle.\nExtracted from ChatLive.Home.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers
  alias Elektrine.Calls
  alias ElektrineWeb.ChatLive.Operations.Helpers

  def handle_event(
        "initiate_call",
        %{
          "user_id" => callee_id_str,
          "call_type" => call_type,
          "conversation_id" => conversation_id_str
        } = _params,
        socket
      ) do
    with {:ok, callee_id} <- parse_integer(callee_id_str),
         {:ok, conversation_id} <- parse_optional_integer(conversation_id_str) do
      caller_id = socket.assigns.current_user.id

      case Calls.initiate_call(caller_id, callee_id, call_type, conversation_id) do
        {:ok, call} ->
          full_call = Calls.get_call_with_users(call.id) || call

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "user:#{full_call.callee_id}",
            {:incoming_call, full_call}
          )

          call_state = %{
            socket.assigns.call
            | active_call: full_call,
              incoming_call: nil,
              status: "calling",
              audio_enabled: true,
              video_enabled: full_call.call_type == "video"
          }

          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
           |> assign(:call, call_state)
           |> push_event("start_call", %{
             call_id: full_call.id,
             call_type: full_call.call_type,
             ice_servers: ice_servers(),
             user_token: user_token(socket)
           })}

        {:error, :caller_already_in_call} ->
          {:noreply, notify_error(socket, "You're already in a call")}

        {:error, :callee_already_in_call} ->
          {:noreply, notify_error(socket, "This user is already in another call")}

        {:error, :rate_limit_exceeded} ->
          {:noreply,
           notify_error(socket, "You're starting calls too quickly. Try again shortly.")}

        {:error, reason} ->
          error_msg = Elektrine.Privacy.privacy_error_message(reason)
          {:noreply, notify_error(socket, error_msg)}
      end
    else
      {:error, :invalid_integer} -> {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("answer_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        case Calls.answer_call(call_id) do
          {:ok, call} ->
            full_call =
              socket.assigns.call.incoming_call || socket.assigns.call.active_call ||
                Calls.get_call_with_users(call.id)

            call_state = %{
              socket.assigns.call
              | incoming_call: nil,
                active_call: full_call,
                status: "connecting",
                audio_enabled: true,
                video_enabled: not is_nil(full_call) and full_call.call_type == "video"
            }

            {:noreply,
             socket
             |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
             |> assign(:call, call_state)
             |> push_event("stop_ringtone", %{})
             |> push_event("answer_call", %{
               call_id: call_id,
               ice_servers: ice_servers(),
               user_token: user_token(socket)
             })}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to answer call")}
        end

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("reject_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        _ = Calls.reject_call(call_id)

        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
         |> assign(:call, reset_call_state(socket.assigns.call))
         |> push_event("stop_ringtone", %{})
         |> push_event("reject_call", %{call_id: call_id, user_token: user_token(socket)})}

      {:error, :invalid_integer} ->
        {:noreply, notify_error(socket, "Invalid call request")}
    end
  end

  def handle_event("end_call", %{"call_id" => call_id}, socket) do
    case parse_integer(call_id) do
      {:ok, call_id} ->
        _ = Calls.end_call(call_id)

        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
         |> assign(:call, reset_call_state(socket.assigns.call))
         |> push_event("stop_ringtone", %{})}

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
    if socket.assigns.call.active_call do
      _ = Calls.update_call_status(socket.assigns.call.active_call.id, "failed")
    end

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
    if socket.assigns.call.active_call do
      _ = Calls.end_call(socket.assigns.call.active_call.id)
    end

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

  defp ice_servers do
    :elektrine |> Application.get_env(:webrtc, []) |> Keyword.get(:ice_servers, [])
  end
end
