defmodule ElektrineWeb.CallChannel do
  @moduledoc false
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
    ElektrineWeb.Presence.track(
      self(),
      "call:#{socket.assigns.call_id}",
      to_string(socket.assigns.user_id),
      %{user_id: socket.assigns.user_id, online_at: System.system_time(:second)}
    )

    push(socket, "presence_state", ElektrineWeb.Presence.list("call:#{socket.assigns.call_id}"))
    push(socket, "joined", %{user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  @impl true
  def handle_info(:ring_timeout, socket) do
    call = Calls.get_call(socket.assigns.call_id) |> Repo.preload([:caller, :callee])

    if call && call.status == "ringing" do
      Calls.miss_call(socket.assigns.call_id)
      Phoenix.PubSub.broadcast(Elektrine.PubSub, "user:#{call.caller_id}", {:call_missed, call})
      Phoenix.PubSub.broadcast(Elektrine.PubSub, "user:#{call.callee_id}", {:call_missed, call})
      broadcast!(socket, "call_missed", %{reason: "timeout"})
      {:stop, :normal, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in("ready_to_receive", _params, socket) do
    broadcast_from!(socket, "peer_ready", %{user_id: socket.assigns.user_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    case validate_sdp(sdp, "offer") do
      :ok ->
        Calls.update_call_status(socket.assigns.call_id, "ringing")
        Process.send_after(self(), :ring_timeout, Constants.call_ring_timeout_ms())
        broadcast_from!(socket, "offer", %{sdp: sdp, from_user_id: socket.assigns.user_id})
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
        Calls.update_call_status(socket.assigns.call_id, "active")
        broadcast_from!(socket, "answer", %{sdp: sdp, from_user_id: socket.assigns.user_id})
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
        broadcast_from!(socket, "ice_candidate", %{
          candidate: candidate,
          from_user_id: socket.assigns.user_id
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("Invalid ICE candidate from user #{socket.assigns.user_id}: #{reason}")
        {:reply, {:error, %{reason: "invalid_candidate"}}, socket}
    end
  end

  @impl true
  def handle_in("reject_call", _params, socket) do
    Calls.reject_call(socket.assigns.call_id)
    broadcast!(socket, "call_rejected", %{by_user_id: socket.assigns.user_id})
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
    broadcast!(socket, "call_ended", %{by_user_id: socket.assigns.user_id})
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

  @impl true
  def terminate(reason, socket) do
    if reason != :normal do
      call = Calls.get_call(socket.assigns.call_id)

      if call && call.status in ["initiated", "ringing", "active"] do
        Calls.update_call_status(socket.assigns.call_id, "ended")

        broadcast!(socket, "call_ended", %{
          by_user_id: socket.assigns.user_id,
          reason: "disconnected"
        })

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
