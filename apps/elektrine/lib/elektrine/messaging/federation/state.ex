defmodule Elektrine.Messaging.Federation.State do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor

  alias Elektrine.Messaging.{
    ChatMessage,
    Conversation,
    FederationAccountPresenceState,
    FederationExtensionEvent,
    FederationInviteState,
    FederationMembershipState,
    FederationReadCursor,
    FederationRoomPresenceState
  }

  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  def upsert_remote_read_cursor(
        conversation_id,
        chat_message_id,
        remote_actor_id,
        remote_domain,
        read_at,
        read_through_sequence,
        _context
      )
      when is_integer(conversation_id) and is_integer(chat_message_id) and
             is_integer(remote_actor_id) and is_binary(remote_domain) do
    attrs = %{
      conversation_id: conversation_id,
      chat_message_id: chat_message_id,
      remote_actor_id: remote_actor_id,
      origin_domain: String.downcase(remote_domain),
      read_at: read_at || DateTime.utc_now(),
      read_through_sequence: normalize_positive_int(read_through_sequence)
    }

    case Repo.get_by(FederationReadCursor,
           conversation_id: conversation_id,
           remote_actor_id: remote_actor_id
         ) do
      nil ->
        %FederationReadCursor{}
        |> FederationReadCursor.changeset(attrs)
        |> Repo.insert()

      %FederationReadCursor{} = cursor when cursor.chat_message_id > chat_message_id ->
        {:ok, cursor}

      %FederationReadCursor{} = cursor ->
        cursor
        |> FederationReadCursor.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_remote_read_cursor(
        _conversation_id,
        _chat_message_id,
        _remote_actor_id,
        _remote_domain,
        _read_at,
        _read_through_sequence,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def maybe_broadcast_remote_read_cursor(
        conversation_id,
        chat_message_id,
        remote_actor_id,
        context
      )
      when is_integer(conversation_id) and is_integer(chat_message_id) and
             is_integer(remote_actor_id) and is_map(context) do
    case Repo.get(ActivityPubActor, remote_actor_id) do
      %ActivityPubActor{} = actor ->
        label =
          case normalize_optional_string(actor.display_name) do
            nil -> "@#{actor.username}@#{actor.domain}"
            display_name -> "#{display_name} (@#{actor.username}@#{actor.domain})"
          end

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:chat_remote_read_cursor,
           %{
             read_through_message_id: chat_message_id,
             remote_actor_id: remote_actor_id,
             username: label,
             avatar: actor.avatar_url
           }}
        ])

        :ok

      _ ->
        :ok
    end
  end

  def maybe_broadcast_remote_read_cursor(
        _conversation_id,
        _chat_message_id,
        _remote_actor_id,
        _context
      ),
      do: :ok

  def upsert_extension_projection(
        event_type,
        event_key,
        payload,
        remote_domain,
        server_id,
        conversation_id,
        occurred_at,
        status
      )
      when is_binary(event_type) and is_binary(event_key) and is_binary(remote_domain) and
             is_map(payload) do
    event_type = Elektrine.Messaging.ArblargSDK.canonical_event_type(event_type)

    attrs = %{
      event_type: event_type,
      origin_domain: String.downcase(remote_domain),
      event_key: event_key,
      payload: payload,
      status: status,
      occurred_at: occurred_at || DateTime.utc_now(),
      server_id: server_id,
      conversation_id: conversation_id
    }

    case Repo.get_by(FederationExtensionEvent,
           event_type: event_type,
           origin_domain: String.downcase(remote_domain),
           event_key: event_key
         ) do
      nil ->
        %FederationExtensionEvent{}
        |> FederationExtensionEvent.changeset(attrs)
        |> Repo.insert()

      %FederationExtensionEvent{} = event ->
        event
        |> FederationExtensionEvent.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_extension_projection(
        _event_type,
        _event_key,
        _payload,
        _remote_domain,
        _server_id,
        _conversation_id,
        _occurred_at,
        _status
      ),
      do: {:error, :invalid_event_payload}

  def upsert_extension_system_message(
        %Conversation{} = mirror_channel,
        event_type,
        event_key,
        content,
        metadata,
        remote_domain,
        context
      )
      when is_binary(event_type) and is_binary(event_key) and is_binary(content) and
             is_map(metadata) and is_binary(remote_domain) and is_map(context) do
    event_type = Elektrine.Messaging.ArblargSDK.canonical_event_type(event_type)
    federated_source = "arblarg:ext:#{event_type}:#{event_key}"

    attrs = %{
      conversation_id: mirror_channel.id,
      content: content,
      message_type: "system",
      media_metadata: metadata,
      is_federated_mirror: true,
      origin_domain: String.downcase(remote_domain),
      federated_source: federated_source,
      sender_id: nil
    }

    case Repo.get_by(ChatMessage,
           conversation_id: mirror_channel.id,
           federated_source: federated_source
         ) do
      nil ->
        case %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert() do
          {:ok, message} ->
            from(c in Conversation, where: c.id == ^mirror_channel.id)
            |> Repo.update_all(set: [last_message_at: message.inserted_at])

            call(context, :maybe_broadcast_mirror_message_created, [message])

          error ->
            error
        end

      %ChatMessage{} = existing ->
        update_attrs = %{
          content: content,
          media_metadata: metadata,
          edited_at: DateTime.utc_now()
        }

        case existing |> ChatMessage.changeset(update_attrs) |> Repo.update() do
          {:ok, message} ->
            from(c in Conversation, where: c.id == ^mirror_channel.id)
            |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])

            call(context, :maybe_broadcast_mirror_message_updated, [message])

          error ->
            error
        end
    end
  end

  def upsert_extension_system_message(
        _mirror_channel,
        _event_type,
        _event_key,
        _content,
        _metadata,
        _remote_domain,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def upsert_account_presence_state(
        remote_actor_id,
        status,
        activities,
        updated_at,
        remote_domain,
        ttl_ms,
        context
      )
      when is_integer(remote_actor_id) and is_binary(status) and is_binary(remote_domain) and
             is_map(context) do
    effective_updated_at = updated_at || DateTime.utc_now()

    attrs = %{
      remote_actor_id: remote_actor_id,
      status: status,
      origin_domain: String.downcase(remote_domain),
      updated_at_remote: effective_updated_at,
      expires_at_remote: presence_expiry_from_ttl(effective_updated_at, ttl_ms, context),
      activities: %{"items" => normalize_presence_activities(activities)}
    }

    case Repo.get_by(FederationAccountPresenceState, remote_actor_id: remote_actor_id) do
      nil ->
        %FederationAccountPresenceState{}
        |> FederationAccountPresenceState.changeset(attrs)
        |> Repo.insert()

      %FederationAccountPresenceState{} = state ->
        state
        |> FederationAccountPresenceState.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_account_presence_state(
        _remote_actor_id,
        _status,
        _activities,
        _updated_at,
        _remote_domain,
        _ttl_ms,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def upsert_room_presence_state(
        conversation_id,
        remote_actor_id,
        status,
        activities,
        updated_at,
        remote_domain,
        ttl_ms,
        context
      )
      when is_integer(conversation_id) and is_integer(remote_actor_id) and is_binary(status) and
             is_binary(remote_domain) and is_map(context) do
    effective_updated_at = updated_at || DateTime.utc_now()

    attrs = %{
      conversation_id: conversation_id,
      remote_actor_id: remote_actor_id,
      status: status,
      origin_domain: String.downcase(remote_domain),
      updated_at_remote: effective_updated_at,
      expires_at_remote: presence_expiry_from_ttl(effective_updated_at, ttl_ms, context),
      activities: %{"items" => normalize_presence_activities(activities)}
    }

    case Repo.get_by(FederationRoomPresenceState,
           conversation_id: conversation_id,
           remote_actor_id: remote_actor_id
         ) do
      nil ->
        %FederationRoomPresenceState{}
        |> FederationRoomPresenceState.changeset(attrs)
        |> Repo.insert()

      %FederationRoomPresenceState{} = state ->
        state
        |> FederationRoomPresenceState.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_room_presence_state(
        _conversation_id,
        _remote_actor_id,
        _status,
        _activities,
        _updated_at,
        _remote_domain,
        _ttl_ms,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def upsert_membership_state(
        conversation_id,
        remote_actor_id,
        remote_domain,
        role,
        state,
        joined_at,
        updated_at,
        metadata
      )
      when is_integer(conversation_id) and is_integer(remote_actor_id) and
             is_binary(remote_domain) and is_binary(role) and is_binary(state) and
             is_map(metadata) do
    attrs = %{
      conversation_id: conversation_id,
      remote_actor_id: remote_actor_id,
      origin_domain: String.downcase(remote_domain),
      role: role,
      state: state,
      joined_at_remote: joined_at,
      updated_at_remote: updated_at || DateTime.utc_now(),
      metadata: metadata
    }

    case Repo.get_by(FederationMembershipState,
           conversation_id: conversation_id,
           remote_actor_id: remote_actor_id
         ) do
      nil ->
        %FederationMembershipState{}
        |> FederationMembershipState.changeset(attrs)
        |> Repo.insert()

      %FederationMembershipState{} = membership_state ->
        membership_state
        |> FederationMembershipState.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_membership_state(
        _conversation_id,
        _remote_actor_id,
        _remote_domain,
        _role,
        _state,
        _joined_at,
        _updated_at,
        _metadata
      ),
      do: {:error, :invalid_event_payload}

  def upsert_invite_state(
        conversation_id,
        remote_domain,
        actor_payload,
        target_payload,
        role,
        state,
        invited_at,
        updated_at,
        metadata
      )
      when is_integer(conversation_id) and is_binary(remote_domain) and is_map(actor_payload) and
             is_map(target_payload) and is_binary(role) and is_binary(state) and
             is_map(metadata) do
    actor_uri = normalize_optional_string(actor_payload["uri"] || actor_payload["id"])
    target_uri = normalize_optional_string(target_payload["uri"] || target_payload["id"])

    attrs = %{
      conversation_id: conversation_id,
      origin_domain: String.downcase(remote_domain),
      actor_uri: actor_uri,
      actor_payload: actor_payload,
      target_uri: target_uri,
      target_payload: target_payload,
      role: role,
      state: state,
      invited_at_remote: invited_at,
      updated_at_remote: updated_at || DateTime.utc_now(),
      metadata: metadata
    }

    if !is_binary(actor_uri) or !is_binary(target_uri) do
      {:error, :invalid_event_payload}
    else
      case Repo.get_by(FederationInviteState,
             conversation_id: conversation_id,
             target_uri: target_uri
           ) do
        nil ->
          %FederationInviteState{}
          |> FederationInviteState.changeset(attrs)
          |> Repo.insert()

        %FederationInviteState{} = invite_state ->
          invite_state
          |> FederationInviteState.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  def upsert_invite_state(
        _conversation_id,
        _remote_domain,
        _actor_payload,
        _target_payload,
        _role,
        _state,
        _invited_at,
        _updated_at,
        _metadata
      ),
      do: {:error, :invalid_event_payload}

  def persist_local_invite_projection(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        role,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_integer(target_user_id) and
             is_integer(actor_user_id) and is_binary(state) and is_binary(role) and
             is_map(metadata) and is_map(context) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         %User{} = target_user <- Repo.get(User, target_user_id),
         %User{} = actor_user <- Repo.get(User, actor_user_id),
         {:ok, _invite_state} <-
           upsert_invite_state(
             conversation.id,
             call(context, :local_domain, []),
             sender_payload(actor_user),
             sender_payload(target_user),
             role,
             state,
             DateTime.utc_now() |> DateTime.truncate(:second),
             DateTime.utc_now() |> DateTime.truncate(:second),
             metadata
           ) do
      :ok
    else
      nil -> {:error, :invalid_event_payload}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def persist_local_invite_projection(
        _conversation_id,
        _target_user_id,
        _actor_user_id,
        _state,
        _role,
        _metadata,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def persist_local_extension_projection(conversation_id, event_type, payload, context)
      when is_integer(conversation_id) and is_binary(event_type) and is_map(payload) and
             is_map(context) do
    canonical_event_type = Elektrine.Messaging.ArblargSDK.canonical_event_type(event_type)

    normalized_event_type =
      Map.get(
        Elektrine.Messaging.ArblargSDK.schema_bindings(),
        canonical_event_type,
        canonical_event_type
      )

    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         event_key when is_binary(event_key) <-
           local_extension_event_key(normalized_event_type, payload, conversation),
         occurred_at <- local_extension_occurred_at(normalized_event_type, payload),
         status <- local_extension_status(normalized_event_type, payload),
         {:ok, _projection} <-
           upsert_extension_projection(
             canonical_event_type,
             event_key,
             payload,
             call(context, :local_domain, []),
             conversation.server_id,
             conversation.id,
             occurred_at,
             status
           ) do
      :ok
    else
      nil -> {:error, :invalid_event_payload}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def persist_local_extension_projection(_conversation_id, _event_type, _payload, _context),
    do: {:error, :invalid_event_payload}

  def local_presence_subscriber_domains_for_user(user_id) when is_integer(user_id) do
    from(f in Follow,
      join: actor in ActivityPubActor,
      on: actor.id == f.remote_actor_id,
      where:
        f.followed_id == ^user_id and is_nil(f.follower_id) and not is_nil(f.remote_actor_id) and
          f.pending == false,
      where: not is_nil(actor.domain),
      select: actor.domain,
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  def local_presence_subscriber_domains_for_user(_user_id), do: []

  def local_presence_subscriber_user_ids(remote_actor_id) when is_integer(remote_actor_id) do
    from(f in Follow,
      where:
        f.remote_actor_id == ^remote_actor_id and not is_nil(f.follower_id) and
          is_nil(f.followed_id) and f.pending == false,
      select: f.follower_id,
      distinct: true
    )
    |> Repo.all()
  end

  def local_presence_subscriber_user_ids(_remote_actor_id), do: []

  def server_ids_for_remote_actor(remote_actor_id) when is_integer(remote_actor_id) do
    from(state in FederationMembershipState,
      join: conversation in Conversation,
      on: conversation.id == state.conversation_id,
      where: state.remote_actor_id == ^remote_actor_id and state.state == "active",
      where: not is_nil(conversation.server_id),
      select: conversation.server_id,
      distinct: true
    )
    |> Repo.all()
  end

  def server_ids_for_remote_actor(_remote_actor_id), do: []

  defp local_extension_event_key("role.upsert", payload, %Conversation{} = conversation) do
    case get_in(payload, ["role", "id"]) do
      role_id when is_binary(role_id) -> "role:#{role_id}:channel:#{conversation.id}"
      _ -> nil
    end
  end

  defp local_extension_event_key(
         "role.assignment.upsert",
         payload,
         %Conversation{} = conversation
       ) do
    with role_id when is_binary(role_id) <- get_in(payload, ["assignment", "role_id"]),
         target_type when is_binary(target_type) <-
           get_in(payload, ["assignment", "target", "type"]),
         target_id when is_binary(target_id) <- get_in(payload, ["assignment", "target", "id"]) do
      "role_assignment:#{role_id}:#{target_type}:#{target_id}:channel:#{conversation.id}"
    else
      _ -> nil
    end
  end

  defp local_extension_event_key(
         "permission.overwrite.upsert",
         payload,
         %Conversation{} = conversation
       ) do
    case get_in(payload, ["overwrite", "id"]) do
      overwrite_id when is_binary(overwrite_id) ->
        "overwrite:#{overwrite_id}:channel:#{conversation.id}"

      _ ->
        nil
    end
  end

  defp local_extension_event_key("thread.upsert", payload, %Conversation{} = conversation) do
    case get_in(payload, ["thread", "id"]) do
      thread_id when is_binary(thread_id) -> "thread:#{thread_id}:channel:#{conversation.id}"
      _ -> nil
    end
  end

  defp local_extension_event_key("thread.archive", payload, %Conversation{} = conversation) do
    case payload["thread_id"] do
      thread_id when is_binary(thread_id) -> "thread:#{thread_id}:channel:#{conversation.id}"
      _ -> nil
    end
  end

  defp local_extension_event_key(
         "moderation.action.recorded",
         payload,
         %Conversation{} = conversation
       ) do
    case get_in(payload, ["action", "id"]) do
      action_id when is_binary(action_id) -> "moderation:#{action_id}:channel:#{conversation.id}"
      _ -> nil
    end
  end

  defp local_extension_event_key(_event_type, _payload, _conversation), do: nil

  defp local_extension_occurred_at("role.upsert", payload) do
    parse_datetime(get_in(payload, ["role", "updated_at"])) || DateTime.utc_now()
  end

  defp local_extension_occurred_at("thread.archive", payload) do
    parse_datetime(payload["archived_at"]) || DateTime.utc_now()
  end

  defp local_extension_occurred_at("moderation.action.recorded", payload) do
    parse_datetime(get_in(payload, ["action", "occurred_at"])) || DateTime.utc_now()
  end

  defp local_extension_occurred_at(_event_type, _payload), do: DateTime.utc_now()

  defp local_extension_status("role.assignment.upsert", payload),
    do: get_in(payload, ["assignment", "state"])

  defp local_extension_status("thread.upsert", payload), do: get_in(payload, ["thread", "state"])
  defp local_extension_status("thread.archive", _payload), do: "archived"

  defp local_extension_status("moderation.action.recorded", payload),
    do: get_in(payload, ["action", "kind"])

  defp local_extension_status(_event_type, _payload), do: nil

  def maybe_broadcast_presence_update(
        subscriber_user_ids,
        server_ids,
        remote_actor_id,
        status,
        activities,
        updated_at,
        context
      )
      when is_list(subscriber_user_ids) and is_list(server_ids) and is_integer(remote_actor_id) and
             is_binary(status) and is_map(context) do
    actor = Repo.get(ActivityPubActor, remote_actor_id)
    username = if actor, do: actor.username, else: "remote"
    domain = if actor, do: actor.domain, else: call(context, :local_domain, [])
    handle = "@#{username}@#{domain}"

    label =
      case actor && normalize_optional_string(actor.display_name) do
        nil -> handle
        display_name -> "#{display_name} (#{handle})"
      end

    payload = %{
      server_ids: Enum.filter(server_ids, &is_integer/1),
      remote_actor_id: remote_actor_id,
      handle: handle,
      label: label,
      avatar_url: if(actor, do: actor.avatar_url, else: nil),
      status: status,
      activities: normalize_presence_activities(activities),
      updated_at: updated_at || DateTime.utc_now()
    }

    subscriber_user_ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{user_id}",
        {:federation_presence_update, payload}
      )
    end)

    :ok
  end

  def maybe_broadcast_presence_update(
        _subscriber_user_ids,
        _server_ids,
        _remote_actor_id,
        _status,
        _activities,
        _updated_at,
        _context
      ),
      do: :ok

  def maybe_broadcast_room_presence_update(
        conversation_id,
        remote_actor_id,
        status,
        activities,
        updated_at,
        context
      )
      when is_integer(conversation_id) and is_integer(remote_actor_id) and is_binary(status) and
             is_map(context) do
    case Repo.get(ActivityPubActor, remote_actor_id) do
      %ActivityPubActor{} = actor ->
        handle = "@#{actor.username}@#{actor.domain}"

        label =
          case normalize_optional_string(actor.display_name) do
            nil -> handle
            display_name -> "#{display_name} (#{handle})"
          end

        payload = %{
          conversation_id: conversation_id,
          remote_actor_id: remote_actor_id,
          handle: handle,
          label: label,
          avatar_url: actor.avatar_url,
          status: status,
          activities: normalize_presence_activities(activities),
          updated_at: updated_at || DateTime.utc_now()
        }

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:federation_presence_update, payload}
        ])

        :ok

      _ ->
        :ok
    end
  end

  def maybe_broadcast_room_presence_update(
        _conversation_id,
        _remote_actor_id,
        _status,
        _activities,
        _updated_at,
        _context
      ),
      do: :ok

  def maybe_broadcast_membership_state(conversation_id, membership_state, context)
      when is_integer(conversation_id) and is_map(context) do
    case Repo.get(ActivityPubActor, membership_state.remote_actor_id) do
      %ActivityPubActor{} = actor ->
        payload = %{
          conversation_id: conversation_id,
          remote_actor_id: membership_state.remote_actor_id,
          handle: "@#{actor.username}@#{actor.domain}",
          role: membership_state.role,
          state: membership_state.state,
          joined_at: membership_state.joined_at_remote,
          updated_at: membership_state.updated_at_remote,
          avatar_url: actor.avatar_url
        }

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:federation_membership_update, payload}
        ])

        :ok

      _ ->
        :ok
    end
  end

  def maybe_broadcast_membership_state(_conversation_id, _membership_state, _context), do: :ok

  def maybe_broadcast_remote_typing_started(conversation_id, remote_actor_id, context)
      when is_integer(conversation_id) and is_integer(remote_actor_id) and is_map(context) do
    case Repo.get(ActivityPubActor, remote_actor_id) do
      %ActivityPubActor{} = actor ->
        label =
          case normalize_optional_string(actor.display_name) do
            nil -> "@#{actor.username}@#{actor.domain}"
            display_name -> "#{display_name} (@#{actor.username}@#{actor.domain})"
          end

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:user_typing, remote_actor_typing_key(actor), label}
        ])

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:user_typing, conversation_id, remote_actor_typing_key(actor), label}
        ])

        :ok

      _ ->
        :ok
    end
  end

  def maybe_broadcast_remote_typing_started(_conversation_id, _remote_actor_id, _context), do: :ok

  def maybe_broadcast_remote_typing_stopped(conversation_id, remote_actor_id, context)
      when is_integer(conversation_id) and is_integer(remote_actor_id) and is_map(context) do
    case Repo.get(ActivityPubActor, remote_actor_id) do
      %ActivityPubActor{} = actor ->
        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:user_stopped_typing, remote_actor_typing_key(actor)}
        ])

        call(context, :broadcast_conversation_event, [
          conversation_id,
          {:user_stopped_typing, conversation_id, remote_actor_typing_key(actor)}
        ])

        :ok

      _ ->
        :ok
    end
  end

  def maybe_broadcast_remote_typing_stopped(_conversation_id, _remote_actor_id, _context), do: :ok

  def normalize_presence_activities(activities) when is_list(activities) do
    activities
    |> Enum.filter(&is_map/1)
    |> Enum.take(10)
  end

  def normalize_presence_activities(%{"items" => activities}) when is_list(activities) do
    normalize_presence_activities(activities)
  end

  def normalize_presence_activities(%{items: activities}) when is_list(activities) do
    normalize_presence_activities(activities)
  end

  def normalize_presence_activities(_activities), do: []

  def invite_membership_state(state) when state in ["pending"], do: "invited"
  def invite_membership_state(state) when state in ["accepted"], do: "active"
  def invite_membership_state(_state), do: "left"

  def ban_membership_state(state) when state == "active", do: "banned"
  def ban_membership_state(_state), do: "left"

  def expired_presence_state?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  def expired_presence_state?(_expires_at), do: false

  defp presence_expiry_from_ttl(%DateTime{} = updated_at, ttl_ms, context) do
    effective_ttl_ms =
      case ttl_ms do
        ttl when is_integer(ttl) and ttl > 0 -> ttl
        _ -> call(context, :presence_ttl_seconds, []) * 1_000
      end

    DateTime.add(updated_at, effective_ttl_ms, :millisecond)
  end

  defp presence_expiry_from_ttl(_updated_at, _ttl_ms, _context), do: nil

  defp remote_actor_typing_key(%ActivityPubActor{} = actor) do
    "remote:#{actor.id}:#{actor.domain}"
  end

  defp remote_actor_typing_key(_actor), do: "remote"

  defp normalize_positive_int(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
