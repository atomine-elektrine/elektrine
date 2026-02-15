defmodule ElektrineWeb.CallChannel do
  use ElektrineWeb, :channel
  require Logger

  alias Elektrine.Calls
  alias Elektrine.Constants
  alias Elektrine.Repo

  @impl true
  def join("call:" <> call_id, _params, socket) do
    user_id = socket.assigns.user_id

    case Calls.get_call_with_users(call_id) do
      nil ->
        {:error, %{reason: "call_not_found"}}

      call ->
        # Only caller and callee can join the call
        if call.caller_id == user_id or call.callee_id == user_id do
          socket = assign(socket, :call_id, call_id)
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track presence in the call channel (for channels, use self() not socket)
    ElektrineWeb.Presence.track(
      self(),
      "call:#{socket.assigns.call_id}",
      to_string(socket.assigns.user_id),
      %{
        user_id: socket.assigns.user_id,
        online_at: System.system_time(:second)
      }
    )

    # Push presence state to this socket
    push(socket, "presence_state", ElektrineWeb.Presence.list("call:#{socket.assigns.call_id}"))
    push(socket, "joined", %{user_id: socket.assigns.user_id})

    {:noreply, socket}
  end

  @impl true
  def handle_info(:ring_timeout, socket) do
    call = Calls.get_call(socket.assigns.call_id) |> Repo.preload([:caller, :callee])

    # Only timeout if still ringing
    if call && call.status == "ringing" do
      Calls.miss_call(socket.assigns.call_id)

      # Notify both caller and callee via PubSub
      Phoenix.PubSub.broadcast(Elektrine.PubSub, "user:#{call.caller_id}", {:call_missed, call})
      Phoenix.PubSub.broadcast(Elektrine.PubSub, "user:#{call.callee_id}", {:call_missed, call})

      broadcast!(socket, "call_missed", %{
        reason: "timeout"
      })

      {:stop, :normal, socket}
    else
      {:noreply, socket}
    end
  end

  # WebRTC Signaling Messages

  @impl true
  def handle_in("ready_to_receive", _params, socket) do
    # Notify the other peer that this peer is ready
    broadcast_from!(socket, "peer_ready", %{
      user_id: socket.assigns.user_id
    })

    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    # Security: Validate SDP
    with :ok <- validate_sdp(sdp, "offer") do
      # Update call status to ringing when offer is sent
      Calls.update_call_status(socket.assigns.call_id, "ringing")

      # Start 30-second timeout for ringing
      Process.send_after(self(), :ring_timeout, Constants.call_ring_timeout_ms())

      # Broadcast offer to the other peer
      broadcast_from!(socket, "offer", %{
        sdp: sdp,
        from_user_id: socket.assigns.user_id
      })

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        Logger.warning("Invalid SDP offer from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_sdp"}}, socket}
    end
  end

  @impl true
  def handle_in("answer", %{"sdp" => sdp}, socket) do
    # Security: Validate SDP
    with :ok <- validate_sdp(sdp, "answer") do
      # Update call status to active when answer is received
      Calls.update_call_status(socket.assigns.call_id, "active")

      # Broadcast answer to the other peer
      broadcast_from!(socket, "answer", %{
        sdp: sdp,
        from_user_id: socket.assigns.user_id
      })

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        Logger.warning("Invalid SDP answer from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_sdp"}}, socket}
    end
  end

  @impl true
  def handle_in("ice_candidate", %{"candidate" => candidate}, socket) do
    with :ok <- validate_ice_candidate(candidate) do
      # Broadcast ICE candidate to the other peer
      broadcast_from!(socket, "ice_candidate", %{
        candidate: candidate,
        from_user_id: socket.assigns.user_id
      })

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        Logger.warning("Invalid ICE candidate from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_candidate"}}, socket}
    end
  end

  # Call Control Messages

  @impl true
  def handle_in("reject_call", _params, socket) do
    Calls.reject_call(socket.assigns.call_id)

    # Broadcast to WebRTC channel
    broadcast!(socket, "call_rejected", %{
      by_user_id: socket.assigns.user_id
    })

    # Broadcast to LiveViews via PubSub
    call = Calls.get_call_with_users(socket.assigns.call_id)

    if call do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{call.caller_id}",
        {:call_rejected, call}
      )

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{call.callee_id}",
        {:call_rejected, call}
      )
    end

    {:stop, :normal, :ok, socket}
  end

  @impl true
  def handle_in("end_call", _params, socket) do
    Calls.end_call(socket.assigns.call_id)

    # Broadcast to WebRTC channel
    broadcast!(socket, "call_ended", %{
      by_user_id: socket.assigns.user_id
    })

    # Broadcast to LiveViews via PubSub
    call = Calls.get_call_with_users(socket.assigns.call_id)

    if call do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{call.caller_id}",
        {:call_ended, call}
      )

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{call.callee_id}",
        {:call_ended, call}
      )
    end

    {:stop, :normal, :ok, socket}
  end

  @impl true
  def handle_in("miss_call", _params, socket) do
    Calls.miss_call(socket.assigns.call_id)

    {:reply, :ok, socket}
  end

  # Disconnect handling

  @impl true
  def terminate(reason, socket) do
    # Only end the call if it wasn't already ended by handle_in
    # Normal shutdown means handle_in("end_call") already handled it
    if reason != :normal do
      call = Calls.get_call(socket.assigns.call_id)

      if call && call.status in ["initiated", "ringing", "active"] do
        Calls.update_call_status(socket.assigns.call_id, "ended")

        # Broadcast to WebRTC channel
        broadcast!(socket, "call_ended", %{
          by_user_id: socket.assigns.user_id,
          reason: "disconnected"
        })

        # Broadcast to LiveViews via PubSub
        call = Calls.get_call_with_users(socket.assigns.call_id)

        if call do
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "user:#{call.caller_id}",
            {:call_ended, call}
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "user:#{call.callee_id}",
            {:call_ended, call}
          )
        end
      end
    end

    :ok
  end

  # Security: Validate SDP data
  defp validate_sdp(sdp, expected_type) when is_map(sdp) do
    sdp_string = sdp["sdp"]
    sdp_type = sdp["type"]

    cond do
      # Check type matches expected
      sdp_type != expected_type ->
        {:error, "type_mismatch"}

      # Check SDP string exists and is not empty
      !is_binary(sdp_string) or byte_size(sdp_string) == 0 ->
        {:error, "missing_sdp_string"}

      # Security: Limit SDP size to prevent memory exhaustion
      byte_size(sdp_string) > 100_000 ->
        {:error, "sdp_too_large"}

      # Check basic SDP structure (should start with v=0)
      !String.starts_with?(sdp_string, "v=0") ->
        {:error, "invalid_sdp_format"}

      true ->
        :ok
    end
  end

  defp validate_sdp(_sdp, _expected_type) do
    {:error, "invalid_sdp_structure"}
  end

  # Security: Validate ICE candidate payload before rebroadcasting
  defp validate_ice_candidate(candidate) when is_map(candidate) do
    candidate_line = Map.get(candidate, "candidate")
    sdp_mid = Map.get(candidate, "sdpMid")
    sdp_mline_index = Map.get(candidate, "sdpMLineIndex")
    username_fragment = Map.get(candidate, "usernameFragment")

    cond do
      !is_binary(candidate_line) or candidate_line == "" ->
        {:error, "missing_candidate"}

      byte_size(candidate_line) > 4_096 ->
        {:error, "candidate_too_large"}

      !is_nil(sdp_mid) and (!is_binary(sdp_mid) or byte_size(sdp_mid) > 128) ->
        {:error, "invalid_sdp_mid"}

      !is_nil(sdp_mline_index) and
          (!is_integer(sdp_mline_index) or sdp_mline_index < 0 or sdp_mline_index > 1_024) ->
        {:error, "invalid_sdp_mline_index"}

      !is_nil(username_fragment) and
          (!is_binary(username_fragment) or byte_size(username_fragment) > 256) ->
        {:error, "invalid_username_fragment"}

      true ->
        :ok
    end
  end

  defp validate_ice_candidate(_candidate), do: {:error, "invalid_candidate_structure"}
end
