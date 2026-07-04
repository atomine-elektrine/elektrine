defmodule ElektrineWeb.VoiceChannel do
  @moduledoc """
  Signaling and occupancy channel for community voice channels.

  Topic: `voice:<conversation_id>`.

  Occupancy is tracked with `ElektrineWeb.Presence` on the channel topic, so
  disconnects and crashes untrack automatically. Chat LiveViews subscribe to
  the same PubSub topic and rebuild occupant lists from `presence_diff`
  broadcasts.

  Mesh signaling: clients push `"signal"` messages with a target user id.
  Signals are relayed over the internal `voice_signal:<conversation_id>`
  PubSub topic (separate from the presence topic so LiveViews never receive
  SDP payloads) and pushed only to the targeted user's channel process.

  Initiator rule: the joining peer offers to every occupant that was already
  present (ties across concurrent joins are broken client-side by comparing
  `{joined_at, user_id}` presence metadata).
  """

  use ElektrineWeb, :channel
  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Messaging.VoiceChannels
  alias ElektrineWeb.Presence

  @impl true
  def join("voice:" <> conversation_id_param, _params, socket) do
    user_id = socket.assigns.user_id

    with {:ok, conversation_id} <- parse_conversation_id(conversation_id_param),
         :ok <-
           VoiceChannels.authorize_join(
             conversation_id,
             user_id,
             occupant_user_ids(conversation_id)
           ) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, signal_topic(conversation_id))

      socket = assign(socket, :conversation_id, conversation_id)
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user = Accounts.get_user!(socket.assigns.user_id)

    {:ok, _ref} =
      Presence.track(self(), socket.topic, to_string(user.id), %{
        user_id: user.id,
        username: user.username,
        display_name: user.display_name || user.username,
        avatar: user.avatar,
        muted: false,
        joined_at: System.system_time(:millisecond)
      })

    push(socket, "presence_state", Presence.list(socket.topic))
    {:noreply, socket}
  end

  def handle_info({:voice_signal, %{to: to_user_id} = payload}, socket) do
    if to_user_id == socket.assigns.user_id do
      push(socket, "signal", %{
        from: payload.from,
        kind: payload.kind,
        payload: payload.payload
      })
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_in("signal", %{"to" => to, "kind" => kind, "payload" => payload}, socket) do
    with {:ok, to_user_id} <- parse_target(to),
         :ok <- validate_signal(kind, payload) do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        signal_topic(socket.assigns.conversation_id),
        {:voice_signal,
         %{from: socket.assigns.user_id, to: to_user_id, kind: kind, payload: payload}}
      )

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        Logger.warning(
          "Invalid voice signal from user #{socket.assigns.user_id}: #{inspect(reason)}"
        )

        {:reply, {:error, %{reason: "invalid_signal"}}, socket}
    end
  end

  def handle_in("set_muted", %{"muted" => muted}, socket) when is_boolean(muted) do
    key = to_string(socket.assigns.user_id)

    case Presence.update(self(), socket.topic, key, &Map.put(&1, :muted, muted)) do
      {:ok, _ref} -> {:reply, :ok, socket}
      {:error, _reason} -> {:reply, {:error, %{reason: "not_joined"}}, socket}
    end
  end

  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  defp occupant_user_ids(conversation_id) do
    "voice:#{conversation_id}"
    |> Presence.list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> Enum.map(metas, & &1.user_id) end)
    |> Enum.uniq()
  end

  defp signal_topic(conversation_id), do: "voice_signal:#{conversation_id}"

  defp parse_conversation_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :not_found}
    end
  end

  defp parse_target(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_target(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_target}
    end
  end

  defp parse_target(_value), do: {:error, :invalid_target}

  defp validate_signal("offer", payload), do: validate_sdp(payload, "offer")
  defp validate_signal("answer", payload), do: validate_sdp(payload, "answer")
  defp validate_signal("ice", payload), do: validate_ice_candidate(payload)
  defp validate_signal(_kind, _payload), do: {:error, :unknown_kind}

  defp validate_sdp(%{} = sdp, expected_type) do
    sdp_string = sdp["sdp"]
    sdp_type = sdp["type"]

    cond do
      sdp_type != expected_type -> {:error, :type_mismatch}
      !is_binary(sdp_string) or byte_size(sdp_string) == 0 -> {:error, :missing_sdp_string}
      byte_size(sdp_string) > 100_000 -> {:error, :sdp_too_large}
      !String.starts_with?(sdp_string, "v=0") -> {:error, :invalid_sdp_format}
      true -> :ok
    end
  end

  defp validate_sdp(_sdp, _expected_type), do: {:error, :invalid_sdp_structure}

  defp validate_ice_candidate(%{} = candidate) do
    candidate_line = Map.get(candidate, "candidate")
    sdp_mid = Map.get(candidate, "sdpMid")
    sdp_mline_index = Map.get(candidate, "sdpMLineIndex")

    cond do
      !is_binary(candidate_line) or candidate_line == "" ->
        {:error, :missing_candidate}

      byte_size(candidate_line) > 4096 ->
        {:error, :candidate_too_large}

      !is_nil(sdp_mid) and (!is_binary(sdp_mid) or byte_size(sdp_mid) > 128) ->
        {:error, :invalid_sdp_mid}

      !is_nil(sdp_mline_index) and
          (!is_integer(sdp_mline_index) or sdp_mline_index < 0 or sdp_mline_index > 1024) ->
        {:error, :invalid_sdp_mline_index}

      true ->
        :ok
    end
  end

  defp validate_ice_candidate(_candidate), do: {:error, :invalid_candidate_structure}
end
