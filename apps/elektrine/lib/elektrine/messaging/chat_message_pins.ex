defmodule Elektrine.Messaging.ChatMessagePins do
  @moduledoc """
  Context for pinning chat messages.

  Pins are stored in the `chat_message_pins` join table so pin metadata (who
  pinned and when) is preserved. Pinning requires the `manage_messages`
  permission: for channels this is resolved through `RoomACL`; for DMs and
  groups it maps to the conversation member roles that carry
  `manage_messages` in the built-in role definitions (owner/admin/moderator).

  Pins on channels federate as `pin.upsert` extension events
  (`urn:arblarg:ext:pins:1`), projected last-write-wins per pinned message
  (spec section 7.6: pinned messages as governed room state). Pins in DMs and
  groups stay local.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatConversationMember,
    ChatMessage,
    ChatMessagePin,
    Federation,
    FederationExtensionEvent,
    RoomACL,
    ServerMember
  }

  alias Elektrine.Messaging.Federation.Utils, as: FederationUtils
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  @max_pins_per_conversation 50

  # Built-in conversation roles that carry `manage_messages` (see RoomACL).
  @manage_message_roles ["owner", "admin", "moderator"]

  @doc """
  Maximum number of pinned messages allowed per conversation.
  """
  def max_pins_per_conversation, do: @max_pins_per_conversation

  @doc """
  Pins a message. Requires the `manage_messages` permission in the message's
  conversation. At most #{@max_pins_per_conversation} messages can be pinned
  per conversation.
  """
  def pin_message(message_id, user_id) do
    with %ChatMessage{deleted_at: nil} = message <- fetch_message(message_id),
         :ok <- authorize_manage_messages(message.conversation_id, user_id),
         :ok <- ensure_pin_capacity(message.conversation_id) do
      %ChatMessagePin{}
      |> ChatMessagePin.changeset(%{
        conversation_id: message.conversation_id,
        message_id: message.id,
        pinned_by_id: user_id
      })
      |> Repo.insert()
      |> case do
        {:ok, pin} ->
          pinned_message = message |> ChatMessage.decrypt_content() |> put_pin_state(pin)
          broadcast_pin_event(:message_pinned, pinned_message)
          maybe_publish_pin_state(message, user_id, "pinned", pin.inserted_at)
          {:ok, pinned_message}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :message_id) do
            {:error, :already_pinned}
          else
            {:error, changeset}
          end
      end
    else
      nil -> {:error, :not_found}
      %ChatMessage{} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unpins a message. Requires the `manage_messages` permission in the
  message's conversation.
  """
  def unpin_message(message_id, user_id) do
    with %ChatMessage{} = message <- fetch_message(message_id),
         :ok <- authorize_manage_messages(message.conversation_id, user_id) do
      from(pin in ChatMessagePin, where: pin.message_id == ^message_id)
      |> Repo.delete_all()
      |> case do
        {count, _} when count > 0 ->
          unpinned_message = put_pin_state(message, nil)
          broadcast_pin_event(:message_unpinned, unpinned_message)
          maybe_publish_pin_state(message, user_id, "unpinned", nil)
          {:ok, unpinned_message}

        {0, _} ->
          {:error, :not_pinned}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists the pinned messages of a conversation, newest pin first.
  """
  def list_pinned_messages(conversation_id) do
    from(pin in ChatMessagePin,
      join: message in ChatMessage,
      on: message.id == pin.message_id,
      where: pin.conversation_id == ^conversation_id and is_nil(message.deleted_at),
      order_by: [desc: pin.inserted_at, desc: pin.id],
      preload: [message: [:sender, :link_preview, reply_to: [:sender]]]
    )
    |> Repo.all()
    |> Enum.map(fn pin -> put_pin_state(pin.message, pin) end)
    |> ChatMessage.decrypt_messages()
  end

  @doc """
  Hydrates the virtual pin fields (`is_pinned`, `pinned_at`, `pinned_by_id`)
  on a list of chat messages using a single query.
  """
  def hydrate_pin_state(messages) when is_list(messages) do
    message_ids = messages |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    case message_ids do
      [] ->
        messages

      _ ->
        pins_by_message_id =
          from(pin in ChatMessagePin, where: pin.message_id in ^message_ids)
          |> Repo.all()
          |> Map.new(&{&1.message_id, &1})

        Enum.map(messages, fn message ->
          put_pin_state(message, Map.get(pins_by_message_id, message.id))
        end)
    end
  end

  def hydrate_pin_state(messages), do: messages

  defp put_pin_state(%ChatMessage{} = message, %ChatMessagePin{} = pin) do
    %{message | is_pinned: true, pinned_at: pin.inserted_at, pinned_by_id: pin.pinned_by_id}
  end

  defp put_pin_state(%ChatMessage{} = message, nil) do
    %{message | is_pinned: false, pinned_at: nil, pinned_by_id: nil}
  end

  defp fetch_message(message_id) do
    ChatMessage
    |> Repo.get(message_id)
    |> Repo.preload(:sender)
  end

  defp authorize_manage_messages(conversation_id, user_id)
       when is_integer(conversation_id) and is_integer(user_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{type: "channel", server_id: server_id} when is_integer(server_id) ->
        # Server staff manage channel messages (mirrors `create_server_channel`
        # authorization); other members go through the room ACL.
        if server_staff?(server_id, user_id) do
          :ok
        else
          RoomACL.authorize_local_user_action(conversation_id, user_id, :manage_messages)
        end

      %ChatConversation{type: "channel"} ->
        RoomACL.authorize_local_user_action(conversation_id, user_id, :manage_messages)

      %ChatConversation{} ->
        member =
          from(cm in ChatConversationMember,
            where:
              cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and
                is_nil(cm.left_at)
          )
          |> Repo.one()

        case member do
          %ChatConversationMember{role: role} when role in @manage_message_roles -> :ok
          _ -> {:error, :unauthorized}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp authorize_manage_messages(_conversation_id, _user_id), do: {:error, :unauthorized}

  defp server_staff?(server_id, user_id) do
    from(sm in ServerMember,
      where:
        sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at) and
          sm.role in ^@manage_message_roles
    )
    |> Repo.exists?()
  end

  defp ensure_pin_capacity(conversation_id) do
    count =
      from(pin in ChatMessagePin,
        where: pin.conversation_id == ^conversation_id,
        select: count()
      )
      |> Repo.one()

    if count < @max_pins_per_conversation do
      :ok
    else
      {:error, :pin_limit_reached}
    end
  end

  defp broadcast_pin_event(event, %ChatMessage{} = message) do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      PubSubTopics.conversation(message.conversation_id),
      {event, message}
    )
  end

  ## Federation

  @doc """
  Projects an accepted `pin.upsert` extension event into the local
  `chat_message_pins` rows. The projection row passed in is the current
  last-write-wins state per pinned message, so replays converge. Unknown
  message refs are ignored (the extension event state is still stored).
  Remote-driven pins carry no local `pinned_by_id`.
  """
  def apply_remote_pin_projection(
        %ChatConversation{} = conversation,
        %FederationExtensionEvent{} = projection
      ) do
    with true <- projection.event_type == ArblargSDK.canonical_event_type("pin.upsert"),
         %{} = pin_payload <- projection.payload["pin"],
         ref when is_binary(ref) <- pin_payload["message_id"],
         %ChatMessage{} = message <- resolve_message_by_ref(conversation.id, ref) do
      case pin_payload["state"] do
        "pinned" -> apply_remote_pin(message)
        "unpinned" -> apply_remote_unpin(message)
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  def apply_remote_pin_projection(_conversation, _projection), do: :ok

  defp apply_remote_pin(%ChatMessage{} = message) do
    with nil <- Repo.get_by(ChatMessagePin, message_id: message.id),
         :ok <- ensure_pin_capacity(message.conversation_id),
         {:ok, pin} <-
           %ChatMessagePin{}
           |> ChatMessagePin.changeset(%{
             conversation_id: message.conversation_id,
             message_id: message.id,
             pinned_by_id: nil
           })
           |> Repo.insert(on_conflict: :nothing) do
      pinned_message = message |> ChatMessage.decrypt_content() |> put_pin_state(pin)
      broadcast_pin_event(:message_pinned, pinned_message)
      :ok
    else
      # Already pinned, capacity reached, or conflicting insert: keep local
      # state as-is; the extension projection still records the remote intent.
      _ -> :ok
    end
  end

  defp apply_remote_unpin(%ChatMessage{} = message) do
    from(pin in ChatMessagePin, where: pin.message_id == ^message.id)
    |> Repo.delete_all()
    |> case do
      {count, _} when count > 0 ->
        unpinned_message = message |> ChatMessage.decrypt_content() |> put_pin_state(nil)
        broadcast_pin_event(:message_unpinned, unpinned_message)
        :ok

      _ ->
        :ok
    end
  end

  defp resolve_message_by_ref(conversation_id, ref) do
    Repo.get_by(ChatMessage, conversation_id: conversation_id, federated_source: ref) ||
      resolve_local_message_ref(conversation_id, ref)
  end

  defp resolve_local_message_ref(conversation_id, ref) do
    case String.split(ref, "/_arblarg/messages/") do
      [_base, id_string] ->
        with {message_id, ""} <- Integer.parse(id_string),
             # Re-minting the ref verifies scheme + domain, so foreign refs
             # cannot bind to arbitrary local message ids.
             true <- FederationUtils.message_federation_id(message_id) == ref,
             %ChatMessage{conversation_id: ^conversation_id, federated_source: nil} = message <-
               Repo.get(ChatMessage, message_id) do
          message
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Publishes pin state for channels through the shared governance extension
  # pipeline; DMs and groups stay local. Never blocks the local pin result.
  defp maybe_publish_pin_state(%ChatMessage{} = message, user_id, state, pinned_at)
       when is_integer(user_id) and state in ["pinned", "unpinned"] do
    case Repo.get(ChatConversation, message.conversation_id) do
      %ChatConversation{type: "channel"} ->
        pin_payload =
          %{
            "message_id" =>
              message.federated_source || FederationUtils.message_federation_id(message.id),
            "state" => state,
            "updated_at" => DateTime.to_iso8601(Elektrine.Time.utc_now())
          }
          |> maybe_put_pinned_at(pinned_at)

        _ =
          Federation.publish_extension_event(
            message.conversation_id,
            user_id,
            "pin.upsert",
            %{"pin" => pin_payload}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_publish_pin_state(_message, _user_id, _state, _pinned_at), do: :ok

  defp maybe_put_pinned_at(pin_payload, %DateTime{} = pinned_at) do
    Map.put(pin_payload, "pinned_at", DateTime.to_iso8601(pinned_at))
  end

  defp maybe_put_pinned_at(pin_payload, _pinned_at), do: pin_payload
end
