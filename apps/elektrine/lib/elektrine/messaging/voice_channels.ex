defmodule Elektrine.Messaging.VoiceChannels do
  @moduledoc """
  Domain rules for persistent voice channels inside community servers.

  Voice channels are `chat_conversations` rows with `type: "voice_channel"`.
  They carry no message timeline; occupancy is tracked at the transport layer
  (Phoenix Presence on the `voice:<conversation_id>` topic) and is therefore
  not persisted here. This module owns join authorization and the mesh
  occupancy cap.

  Voice channels are local-only in this iteration: they are excluded from
  federation bootstrap payloads (which only export `type == "channel"` rows)
  and joins on federated mirrors are rejected.
  """

  alias Elektrine.Messaging.{ChatConversation, RoomACL}
  alias Elektrine.Repo

  @default_max_occupants 8

  @doc """
  Maximum number of concurrent occupants in a voice channel (mesh topology).

  Configurable via `config :elektrine, :voice_channels, max_occupants: n`.
  """
  def max_occupants do
    :elektrine
    |> Application.get_env(:voice_channels, [])
    |> Keyword.get(:max_occupants, @default_max_occupants)
  end

  @doc """
  Fetches a conversation only when it is a voice channel.
  """
  def get_voice_channel(conversation_id) when is_integer(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{type: "voice_channel"} = conversation -> conversation
      _ -> nil
    end
  end

  def get_voice_channel(_conversation_id), do: nil

  @doc """
  Authorizes a local user to join a voice channel.

  Requires the conversation to be a local (non-mirror) voice channel and the
  user to be an active member of it; the membership check goes through
  `RoomACL` with the `:send_voice_signaling` action.

  Returns `:ok`, `{:error, :not_found}`, `{:error, :remote_mirror}` or
  `{:error, :unauthorized}`.
  """
  def authorize_join(conversation_id, user_id)
      when is_integer(conversation_id) and is_integer(user_id) do
    case get_voice_channel(conversation_id) do
      nil ->
        {:error, :not_found}

      %ChatConversation{is_federated_mirror: true} ->
        {:error, :remote_mirror}

      %ChatConversation{} ->
        RoomACL.authorize_local_user_action(conversation_id, user_id, :send_voice_signaling)
    end
  end

  def authorize_join(_conversation_id, _user_id), do: {:error, :unauthorized}

  @doc """
  Checks the mesh occupancy cap against the currently connected occupants.

  `occupant_user_ids` is the list of user ids currently tracked in the
  channel's presence. Returns `:ok`, `{:error, :already_joined}` when the
  user is already connected, or `{:error, :channel_full}` when the cap is
  reached.
  """
  def check_capacity(occupant_user_ids, user_id) when is_list(occupant_user_ids) do
    distinct = Enum.uniq(occupant_user_ids)

    cond do
      user_id in distinct -> {:error, :already_joined}
      length(distinct) >= max_occupants() -> {:error, :channel_full}
      true -> :ok
    end
  end

  @doc """
  Combined join check: authorization plus occupancy cap.
  """
  def authorize_join(conversation_id, user_id, occupant_user_ids) do
    with :ok <- authorize_join(conversation_id, user_id) do
      check_capacity(occupant_user_ids, user_id)
    end
  end
end
