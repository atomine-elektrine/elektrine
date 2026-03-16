defmodule ElektrineWeb.CallChannel do
  @moduledoc false
  use ElektrineWeb, :channel
  require Logger
  intercept ["presence_diff"]

  alias Elektrine.Calls
  alias Elektrine.Constants
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.VoiceCalls
  alias Elektrine.PubSubTopics

  @impl true
  def join("call:" <> call_id_param, _params, socket) do
    user_id = socket.assigns.user_id

    with {:ok, call_id} <- parse_call_id(call_id_param) do
      case Calls.get_call_with_users(call_id) do
        nil ->
          join_federated_call(call_id, user_id, socket)

        call ->
          if call.caller_id == user_id or call.callee_id == user_id do
            socket =
              socket
              |> assign(:call_id, call_id)
              |> assign(:call_source, :local)

            send(self(), :after_join)
            {:ok, socket}
          else
            {:error, %{reason: "unauthorized"}}
          end
      end
    else
      :error ->
        {:error, %{reason: "call_not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    PubSubTopics.subscribe(PubSubTopics.call(socket.assigns.call_id))

    ElektrineWeb.Presence.track(
      self(),
      "call:#{socket.assigns.call_id}",
      to_string(socket.assigns.user_id),
      %{user_id: socket.assigns.user_id, online_at: System.system_time(:second)}
    )

    push(socket, "presence_state", ElektrineWeb.Presence.list("call:#{socket.assigns.call_id}"))
    push(socket, "joined", %{user_id: socket.assigns.user_id})

    if socket.assigns.call_source == :federated do
      case VoiceCalls.get_session_for_local_user(socket.assigns.call_id, socket.assigns.user_id) do
        %{status: "active", direction: "outbound"} ->
          push(socket, "peer_ready", %{user_id: socket.assigns.user_id})

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:ring_timeout, socket) do
    if socket.assigns.call_source == :local do
      call = Calls.get_call(socket.assigns.call_id)

      if call && call.status == "ringing" do
        Calls.miss_call(socket.assigns.call_id)
        broadcast!(socket, "call_missed", %{reason: "timeout"})
        {:stop, :normal, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:federated_call_signal, %{kind: "offer", payload: payload}}, socket) do
    push(socket, "offer", %{sdp: payload})
    {:noreply, socket}
  end

  def handle_info({:federated_call_signal, %{kind: "answer", payload: payload}}, socket) do
    push(socket, "answer", %{sdp: payload})
    {:noreply, socket}
  end

  def handle_info({:federated_call_signal, %{kind: "ice", payload: payload}}, socket) do
    push(socket, "ice_candidate", %{candidate: payload})
    {:noreply, socket}
  end

  def handle_info({:federated_peer_ready, _payload}, socket) do
    push(socket, "peer_ready", %{user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  @impl true
  def handle_out("presence_diff", diff, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ready_to_receive", _params, socket) do
    if socket.assigns.call_source == :local do
      broadcast!(socket, "peer_ready", %{user_id: socket.assigns.user_id})
    else
      Federation.publish_dm_call_accept(socket.assigns.call_id)
    end

    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    case validate_sdp(sdp, "offer") do
      :ok ->
        case socket.assigns.call_source do
          :local ->
            case Calls.update_call_status(socket.assigns.call_id, "ringing") do
              {:ok, %{status: "ringing"}} ->
                Process.send_after(self(), :ring_timeout, Constants.call_ring_timeout_ms())

              _ ->
                :ok
            end

            broadcast_from!(socket, "offer", %{sdp: sdp, from_user_id: socket.assigns.user_id})

          :federated ->
            _ = VoiceCalls.mark_session_ringing(socket.assigns.call_id, socket.assigns.user_id)
            Federation.publish_dm_call_signal(socket.assigns.call_id, socket.assigns.user_id, "offer", sdp)
        end

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("Invalid SDP offer from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_sdp"}}, socket}
    end
  end

  @impl true
  def handle_in("answer", %{"sdp" => sdp}, socket) do
    case validate_sdp(sdp, "answer") do
      :ok ->
        case socket.assigns.call_source do
          :local ->
            Calls.update_call_status(socket.assigns.call_id, "active")
            broadcast_from!(socket, "answer", %{sdp: sdp, from_user_id: socket.assigns.user_id})

          :federated ->
            Federation.publish_dm_call_signal(
              socket.assigns.call_id,
              socket.assigns.user_id,
              "answer",
              sdp
            )
        end

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("Invalid SDP answer from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_sdp"}}, socket}
    end
  end

  @impl true
  def handle_in("ice_candidate", %{"candidate" => candidate}, socket) do
    case validate_ice_candidate(candidate) do
      :ok ->
        case socket.assigns.call_source do
          :local ->
            broadcast_from!(socket, "ice_candidate", %{
              candidate: candidate,
              from_user_id: socket.assigns.user_id
            })

          :federated ->
            Federation.publish_dm_call_signal(
              socket.assigns.call_id,
              socket.assigns.user_id,
              "ice",
              candidate
            )
        end

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("Invalid ICE candidate from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_candidate"}}, socket}
    end
  end

  @impl true
  def handle_in("reject_call", _params, socket) do
    case socket.assigns.call_source do
      :local ->
        Calls.reject_call(socket.assigns.call_id)
        broadcast!(socket, "call_rejected", %{by_user_id: socket.assigns.user_id})

      :federated ->
        _ = VoiceCalls.reject_session(socket.assigns.call_id, socket.assigns.user_id)
        Federation.publish_dm_call_reject(socket.assigns.call_id)
    end

    {:stop, :normal, :ok, socket}
  end

  @impl true
  def handle_in("end_call", _params, socket) do
    case socket.assigns.call_source do
      :local ->
        Calls.end_call(socket.assigns.call_id)
        broadcast!(socket, "call_ended", %{by_user_id: socket.assigns.user_id})

      :federated ->
        _ = VoiceCalls.end_session(socket.assigns.call_id, socket.assigns.user_id)
        Federation.publish_dm_call_end(socket.assigns.call_id)
    end

    {:stop, :normal, :ok, socket}
  end

  @impl true
  def handle_in("miss_call", _params, socket) do
    if socket.assigns.call_source == :local do
      Calls.miss_call(socket.assigns.call_id)
    end

    {:reply, :ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    if reason != :normal do
      case socket.assigns.call_source do
        :local ->
          call = Calls.get_call(socket.assigns.call_id)

          if call && call.status in ["initiated", "ringing", "active"] do
            Calls.update_call_status(socket.assigns.call_id, "ended")

            broadcast!(socket, "call_ended", %{
              by_user_id: socket.assigns.user_id,
              reason: "disconnected"
            })
          end

        :federated ->
          case VoiceCalls.get_session_for_local_user(socket.assigns.call_id, socket.assigns.user_id) do
            %{status: status} when status in ["initiated", "ringing", "active"] ->
              _ = VoiceCalls.end_session(socket.assigns.call_id, socket.assigns.user_id, "disconnected")
              Federation.publish_dm_call_end(socket.assigns.call_id)

            _ ->
              :ok
          end
      end
    end

    :ok
  end

  defp join_federated_call(call_id, user_id, socket) do
    case VoiceCalls.get_session_for_local_user(call_id, user_id) do
      nil ->
        {:error, %{reason: "call_not_found"}}

      _session ->
        socket =
          socket
          |> assign(:call_id, call_id)
          |> assign(:call_source, :federated)

        send(self(), :after_join)
        {:ok, socket}
    end
  end

  defp parse_call_id(call_id) when is_binary(call_id) do
    case Integer.parse(call_id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_call_id(call_id) when is_integer(call_id), do: {:ok, call_id}
  defp parse_call_id(_call_id), do: :error

  defp validate_sdp(sdp, expected_type) when is_map(sdp) do
    sdp_string = sdp["sdp"]
    sdp_type = sdp["type"]

    cond do
      sdp_type != expected_type -> {:error, "type_mismatch"}
      !is_binary(sdp_string) or byte_size(sdp_string) == 0 -> {:error, "missing_sdp_string"}
      byte_size(sdp_string) > 100_000 -> {:error, "sdp_too_large"}
      !String.starts_with?(sdp_string, "v=0") -> {:error, "invalid_sdp_format"}
      true -> :ok
    end
  end

  defp validate_sdp(_sdp, _expected_type) do
    {:error, "invalid_sdp_structure"}
  end

  defp validate_ice_candidate(candidate) when is_map(candidate) do
    candidate_line = Map.get(candidate, "candidate")
    sdp_mid = Map.get(candidate, "sdpMid")
    sdp_mline_index = Map.get(candidate, "sdpMLineIndex")
    username_fragment = Map.get(candidate, "usernameFragment")

    cond do
      !is_binary(candidate_line) or candidate_line == "" ->
        {:error, "missing_candidate"}

      byte_size(candidate_line) > 4096 ->
        {:error, "candidate_too_large"}

      !is_nil(sdp_mid) and (!is_binary(sdp_mid) or byte_size(sdp_mid) > 128) ->
        {:error, "invalid_sdp_mid"}

      !is_nil(sdp_mline_index) and
          (!is_integer(sdp_mline_index) or sdp_mline_index < 0 or sdp_mline_index > 1024) ->
        {:error, "invalid_sdp_mline_index"}

      !is_nil(username_fragment) and
          (!is_binary(username_fragment) or byte_size(username_fragment) > 256) ->
        {:error, "invalid_username_fragment"}

      true ->
        :ok
    end
  end

  defp validate_ice_candidate(_candidate) do
    {:error, "invalid_candidate_structure"}
  end
end
