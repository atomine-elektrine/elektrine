defmodule ArblargWeb.ChatLive.Operations.VoiceChannelOperations do
  @moduledoc """
  Voice channel operations for the chat LiveView: joining/leaving voice
  channels, mute toggling, and sidebar occupancy driven by Phoenix Presence
  on the `voice:<conversation_id>` topics.

  The LiveView only orchestrates: the WebRTC mesh itself lives in the
  `VoiceChannel` JS hook, which talks to `ElektrineWeb.VoiceChannel` over the
  user socket (same transport style as 1:1 calls).
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias ArblargWeb.ChatLive.Operations.Helpers
  alias Elektrine.Calls.Transport, as: CallTransport
  alias Elektrine.Messaging.VoiceChannels
  alias ElektrineWeb.Presence

  def handle_event("join_voice_channel", %{"conversation_id" => conversation_id}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, conversation_id} <- parse_positive_int(conversation_id),
         :ok <-
           VoiceChannels.authorize_join(conversation_id, user_id, occupant_ids(conversation_id)) do
      conversation = find_conversation(socket, conversation_id)
      transport = CallTransport.descriptor_for_user(user_id, conversation_id)

      {:noreply,
       socket
       |> assign(:voice, %{
         socket.assigns.voice
         | joined_id: conversation_id,
           joined_name: (conversation && conversation.name) || "Voice channel",
           muted: false
       })
       |> push_event("voice_join", %{
         conversation_id: conversation_id,
         user_id: user_id,
         user_token: user_token(socket),
         ice_servers: transport["ice_servers"],
         transport: transport
       })}
    else
      {:error, :channel_full} ->
        {:noreply, notify_error(socket, "This voice channel is full")}

      {:error, :already_joined} ->
        {:noreply, notify_error(socket, "You're already connected to this voice channel")}

      {:error, :remote_mirror} ->
        {:noreply,
         notify_error(socket, "Voice channels on remote servers can't be joined from here")}

      {:error, :not_found} ->
        {:noreply, notify_error(socket, "Voice channel not found")}

      _ ->
        {:noreply, notify_error(socket, "You don't have access to this voice channel")}
    end
  end

  def handle_event("leave_voice_channel", _params, socket) do
    {:noreply,
     socket
     |> assign(:voice, reset_connection(socket.assigns.voice))
     |> push_event("voice_leave", %{})}
  end

  def handle_event("toggle_voice_mute", _params, socket) do
    {:noreply, push_event(socket, "voice_toggle_mute", %{})}
  end

  # Confirmations and errors reported back by the VoiceChannel JS hook.

  def handle_event("voice_joined", _params, socket) do
    {:noreply, socket}
  end

  # Sent by the hook after a LiveView reconnect while a media session is
  # still running, so the connected bar reflects reality again.
  def handle_event("voice_rejoined", %{"conversation_id" => conversation_id} = params, socket) do
    case parse_positive_int(conversation_id) do
      {:ok, conversation_id} ->
        conversation = find_conversation(socket, conversation_id)

        {:noreply,
         assign(socket, :voice, %{
           socket.assigns.voice
           | joined_id: conversation_id,
             joined_name: (conversation && conversation.name) || "Voice channel",
             muted: params["muted"] == true
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("voice_left", _params, socket) do
    {:noreply, assign(socket, :voice, reset_connection(socket.assigns.voice))}
  end

  def handle_event("voice_mute_changed", %{"muted" => muted}, socket) do
    {:noreply, assign(socket, :voice, %{socket.assigns.voice | muted: muted == true})}
  end

  def handle_event("voice_error", params, socket) do
    {:noreply,
     socket
     |> assign(:voice, reset_connection(socket.assigns.voice))
     |> notify_error(voice_error_message(params["reason"]))}
  end

  @doc """
  Handles presence diffs broadcast on `voice:<conversation_id>` topics.

  Returns `{:handled, result}` or `:unhandled` (same contract as the other
  `route_info` operation modules).
  """
  def route_info(
        %Phoenix.Socket.Broadcast{topic: "voice:" <> conversation_id, event: "presence_diff"},
        socket
      ) do
    case parse_positive_int(conversation_id) do
      {:ok, conversation_id} ->
        occupants =
          Map.put(
            socket.assigns.voice.occupants,
            conversation_id,
            occupants_for(conversation_id)
          )

        {:handled,
         {:noreply, assign(socket, :voice, %{socket.assigns.voice | occupants: occupants})}}

      _ ->
        {:handled, {:noreply, socket}}
    end
  end

  def route_info(%Phoenix.Socket.Broadcast{topic: "voice:" <> _rest}, socket) do
    {:handled, {:noreply, socket}}
  end

  def route_info(_info, _socket), do: :unhandled

  @doc """
  Subscribes the LiveView to the presence topics of every voice channel in
  the conversation list and refreshes occupant snapshots. Call whenever the
  conversation list is (re)loaded.
  """
  def sync_voice_channels(socket, conversations) when is_list(conversations) do
    voice_ids =
      conversations
      |> Enum.filter(&(&1.type == "voice_channel"))
      |> MapSet.new(& &1.id)

    subscribed = socket.assigns.voice.subscribed_ids

    if connected?(socket) do
      Enum.each(MapSet.difference(voice_ids, subscribed), fn id ->
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "voice:#{id}")
      end)

      Enum.each(MapSet.difference(subscribed, voice_ids), fn id ->
        Phoenix.PubSub.unsubscribe(Elektrine.PubSub, "voice:#{id}")
      end)
    end

    occupants = Map.new(voice_ids, fn id -> {id, occupants_for(id)} end)

    assign(socket, :voice, %{
      socket.assigns.voice
      | subscribed_ids: voice_ids,
        occupants: occupants
    })
  end

  def sync_voice_channels(socket, _conversations), do: socket

  @doc """
  Occupant maps (user_id, username, display_name, avatar, muted) for one
  voice channel, ordered by join time.
  """
  def occupants_for(conversation_id) do
    "voice:#{conversation_id}"
    |> Presence.list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> Enum.take(metas, 1) end)
    |> Enum.sort_by(&{Map.get(&1, :joined_at, 0), Map.get(&1, :user_id, 0)})
    |> Enum.map(
      &%{
        user_id: Map.get(&1, :user_id),
        username: Map.get(&1, :username),
        display_name: Map.get(&1, :display_name) || Map.get(&1, :username),
        avatar: Map.get(&1, :avatar),
        muted: Map.get(&1, :muted, false)
      }
    )
  end

  defp occupant_ids(conversation_id) do
    conversation_id
    |> occupants_for()
    |> Enum.map(& &1.user_id)
  end

  defp find_conversation(socket, conversation_id) do
    Enum.find(socket.assigns.conversation.list, &(&1.id == conversation_id))
  end

  defp reset_connection(voice_state) do
    %{voice_state | joined_id: nil, joined_name: nil, muted: false}
  end

  defp voice_error_message("channel_full"), do: "This voice channel is full"
  defp voice_error_message("already_joined"), do: "You're already connected in another tab"

  defp voice_error_message("unauthorized"),
    do: "You don't have access to this voice channel"

  defp voice_error_message(reason) when is_binary(reason) and reason != "",
    do: "Voice channel error: #{reason}"

  defp voice_error_message(_reason), do: "Voice channel connection failed"

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_positive_int(_value), do: {:error, :invalid_id}

  defp user_token(socket) do
    socket.assigns[:user_token] || Helpers.generate_user_token(socket.assigns.current_user.id)
  end
end
