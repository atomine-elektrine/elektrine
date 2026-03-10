defmodule Elektrine.Messaging.Federation.MirrorBroadcasts do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    ChatMessage,
    ChatMessageReaction,
    ChatMessages,
    Conversation,
    Server
  }
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  def add_mirror_reaction(chat_message_id, remote_actor_id, emoji)
      when is_integer(chat_message_id) and is_integer(remote_actor_id) and is_binary(emoji) do
    case Repo.get_by(ChatMessageReaction,
           chat_message_id: chat_message_id,
           remote_actor_id: remote_actor_id,
           emoji: emoji
         ) do
      nil ->
        %ChatMessageReaction{}
        |> ChatMessageReaction.changeset(%{
          chat_message_id: chat_message_id,
          remote_actor_id: remote_actor_id,
          emoji: emoji
        })
        |> Repo.insert()
        |> case do
          {:ok, reaction} -> {:ok, reaction}
          {:error, reason} -> {:error, reason}
        end

      _existing ->
        {:ok, :duplicate}
    end
  end

  def add_mirror_reaction(_chat_message_id, _remote_actor_id, _emoji),
    do: {:error, :invalid_event_payload}

  def remove_mirror_reaction(chat_message_id, remote_actor_id, emoji)
      when is_integer(chat_message_id) and is_integer(remote_actor_id) and is_binary(emoji) do
    {removed_count, _} =
      from(r in ChatMessageReaction,
        where:
          r.chat_message_id == ^chat_message_id and
            r.remote_actor_id == ^remote_actor_id and
            r.emoji == ^emoji
      )
      |> Repo.delete_all()

    {:ok, removed_count}
  end

  def remove_mirror_reaction(_chat_message_id, _remote_actor_id, _emoji),
    do: {:error, :invalid_event_payload}

  def maybe_broadcast_mirror_message_created(:duplicate), do: :ok

  def maybe_broadcast_mirror_message_created(%ChatMessage{
        id: message_id,
        conversation_id: conversation_id
      }) do
    case ChatMessages.get_message_decrypted(message_id) do
      %ChatMessage{} = message ->
        broadcast_conversation_event(conversation_id, {:new_chat_message, message})

      _ ->
        :ok
    end
  end

  def maybe_broadcast_mirror_message_created(_message), do: :ok

  def maybe_broadcast_mirror_message_updated(%ChatMessage{
        id: message_id,
        conversation_id: conversation_id
      }) do
    case ChatMessages.get_message_decrypted(message_id) do
      %ChatMessage{} = message ->
        broadcast_conversation_event(conversation_id, {:chat_message_updated, message})

      _ ->
        :ok
    end
  end

  def maybe_broadcast_mirror_message_updated(_message), do: :ok

  def maybe_broadcast_mirror_message_deleted(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        broadcast_conversation_event(conversation_id, {:chat_message_deleted, message_id})

      _ ->
        :ok
    end
  end

  def maybe_broadcast_mirror_message_deleted(_message_id), do: :ok

  def maybe_broadcast_mirror_reaction_added(_message_id, :duplicate), do: :ok

  def maybe_broadcast_mirror_reaction_added(message_id, %ChatMessageReaction{} = reaction)
      when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        reaction = Repo.preload(reaction, [:user, :remote_actor])

        broadcast_conversation_event(
          conversation_id,
          {:chat_reaction_added, message_id, reaction}
        )

      _ ->
        :ok
    end
  end

  def maybe_broadcast_mirror_reaction_added(_message_id, _reaction), do: :ok

  def maybe_broadcast_mirror_reaction_removed(
        _message_id,
        _remote_actor_id,
        _emoji,
        removed_count
      )
      when removed_count <= 0,
      do: :ok

  def maybe_broadcast_mirror_reaction_removed(message_id, remote_actor_id, emoji, _removed_count)
      when is_integer(message_id) and is_integer(remote_actor_id) and is_binary(emoji) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        broadcast_conversation_event(
          conversation_id,
          {:chat_reaction_removed, message_id, nil, emoji, remote_actor_id}
        )

      _ ->
        :ok
    end
  end

  def maybe_broadcast_mirror_reaction_removed(_message_id, _remote_actor_id, _emoji, _removed_count),
    do: :ok

  def broadcast_conversation_event(conversation_id, event) when is_integer(conversation_id) do
    topic = PubSubTopics.conversation(conversation_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, event)
  end

  def publish_latest_message_event(conversation_id, context)
      when is_integer(conversation_id) and is_map(context) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{type: "channel", server_id: server_id} when not is_nil(server_id) ->
        case Repo.get(Server, server_id) do
          %Server{is_federated_mirror: false} ->
            from(m in ChatMessage,
              where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
              order_by: [desc: m.inserted_at],
              limit: 1
            )
            |> Repo.one()
            |> case do
              nil -> :ok
              latest -> call(context, :publish_message_created, [latest])
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def publish_latest_message_event(_conversation_id, _context), do: :ok

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
