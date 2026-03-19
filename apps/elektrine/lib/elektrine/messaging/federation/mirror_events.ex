defmodule Elektrine.Messaging.Federation.MirrorEvents do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub

  alias Elektrine.Messaging.{
    CommunityBan,
    Conversation,
    ConversationMember,
    Federation,
    FederationMembershipState,
    Server,
    ServerMember
  }

  alias Elektrine.Repo

  def apply_event(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    case event_type do
      "server.upsert" -> apply_server_upsert(data, remote_domain, context)
      "message.create" -> apply_message_create(data, remote_domain, context)
      "message.update" -> apply_message_update(data, remote_domain, context)
      "message.delete" -> apply_message_delete(data, remote_domain, context)
      "reaction.add" -> apply_reaction_add(data, remote_domain, context)
      "reaction.remove" -> apply_reaction_remove(data, remote_domain, context)
      "read.cursor" -> apply_read_cursor(data, remote_domain, context)
      "invite.upsert" -> apply_invite_upsert(data, remote_domain, context)
      "ban.upsert" -> apply_ban_upsert(data, remote_domain, context)
      "membership.upsert" -> apply_membership_upsert(data, remote_domain, context)
      "presence.update" -> apply_presence_update(data, remote_domain, context)
      "typing.start" -> apply_typing_start(data, remote_domain, context)
      "typing.stop" -> apply_typing_stop(data, remote_domain, context)
      _ -> {:error, :unhandled_event_type}
    end
  end

  defp apply_server_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         {:ok, mirror_server} <-
           call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, _channel_map} <-
           call(context, :upsert_mirror_channels, [mirror_server, data["channels"] || []]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_message_create(data, remote_domain, context) do
    with %{} = message_payload <- data["message"],
         %{} = sender_payload <- message_payload["sender"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [sender_payload, remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         {:ok, mirror_message_or_duplicate} <-
           call(context, :upsert_mirror_message, [channel, message_payload, remote_domain]),
         :ok <-
           call(context, :maybe_broadcast_mirror_message_created, [mirror_message_or_duplicate]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_message_update(data, remote_domain, context) do
    with %{} = message_payload <- data["message"],
         %{} = sender_payload <- message_payload["sender"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [sender_payload, remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         :ok <-
           call(context, :ensure_remote_message_author, [
             channel,
             message_payload["id"],
             remote_domain
           ]),
         {:ok, mirror_message} <-
           call(context, :upsert_or_update_mirror_message, [
             channel,
             message_payload,
             remote_domain
           ]),
         :ok <- call(context, :maybe_broadcast_mirror_message_updated, [mirror_message]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_message_delete(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         :ok <-
           call(context, :ensure_remote_message_author, [channel, message_id, remote_domain]),
         {:ok, deleted_message} <-
           call(context, :soft_delete_mirror_message, [
             channel,
             message_id,
             data["deleted_at"],
             remote_domain
           ]),
         :ok <- call(context, :maybe_broadcast_mirror_message_deleted, [deleted_message.id]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_reaction_add(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, message} <- call(context, :get_mirror_message, [channel, message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [reaction["actor"], remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         {:ok, reaction_or_duplicate} <-
           call(context, :add_mirror_reaction, [message.id, remote_actor_id, emoji]),
         :ok <-
           call(context, :maybe_broadcast_mirror_reaction_added, [
             message.id,
             reaction_or_duplicate
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_reaction_remove(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, message} <- call(context, :get_mirror_message, [channel, message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [reaction["actor"], remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         {:ok, removed_count} <-
           call(context, :remove_mirror_reaction, [message.id, remote_actor_id, emoji]),
         :ok <-
           call(context, :maybe_broadcast_mirror_reaction_removed, [
             message.id,
             remote_actor_id,
             emoji,
             removed_count
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_read_cursor(data, remote_domain, context) do
    with read_through_message_id when is_binary(read_through_message_id) <-
           data["read_through_message_id"],
         %{} = actor_payload <- data["actor"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, message} <-
           call(context, :get_mirror_message, [channel, read_through_message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :read
           ]),
         read_at <- call(context, :parse_datetime, [data["read_at"]]) || DateTime.utc_now(),
         read_through_sequence <- call(context, :parse_int, [data["read_through_sequence"], 0]),
         {:ok, _cursor} <-
           call(context, :upsert_remote_read_cursor, [
             channel.id,
             message.id,
             remote_actor_id,
             remote_domain,
             read_at,
             read_through_sequence
           ]),
         :ok <-
           call(context, :maybe_broadcast_remote_read_cursor, [
             channel.id,
             message.id,
             remote_actor_id
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_invite_upsert(data, remote_domain, context) do
    with %{} = invite_payload <- data["invite"],
         %{} = target_payload <- invite_payload["target"],
         %{} = actor_payload <- invite_payload["actor"],
         state when is_binary(state) <- invite_payload["state"],
         role when is_binary(role) <- invite_payload["role"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :invite,
             context
           ),
         {:ok, _invite_state} <-
           call(context, :upsert_invite_state, [
             mirror_channel.id,
             remote_domain,
             actor_payload,
             target_payload,
             role,
             state,
             call(context, :parse_datetime, [invite_payload["invited_at"]]),
             call(context, :parse_datetime, [invite_payload["updated_at"]]) || DateTime.utc_now(),
             invite_payload["metadata"] || %{}
           ]),
         :ok <-
           apply_invite_target_projection(
             mirror_channel,
             target_payload,
             remote_domain,
             remote_actor_id,
             role,
             state,
             invite_payload,
             context
           ) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_ban_upsert(data, remote_domain, context) do
    with %{} = ban_payload <- data["ban"],
         %{} = target_payload <- ban_payload["target"],
         %{} = actor_payload <- ban_payload["actor"],
         state when is_binary(state) <- ban_payload["state"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :ban,
             context
           ),
         :ok <-
           apply_ban_target_projection(
             mirror_channel,
             target_payload,
             remote_domain,
             remote_actor_id,
             state,
             ban_payload,
             context
           ) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_membership_upsert(data, remote_domain, context) do
    with %{} = membership_payload <- data["membership"],
         %{} = actor_payload <- membership_payload["actor"],
         state when is_binary(state) <- membership_payload["state"],
         role when is_binary(role) <- membership_payload["role"],
         {:ok, server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           apply_membership_projection(
             server,
             channel,
             remote_actor_id,
             remote_domain,
             role,
             state,
             membership_payload,
             context
           ) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_presence_update(data, remote_domain, context) do
    with %{} = presence_payload <- data["presence"],
         %{} = actor_payload <- presence_payload["actor"],
         status when is_binary(status) <- presence_payload["status"],
         updated_at <-
           call(context, :parse_datetime, [presence_payload["updated_at"]]) || DateTime.utc_now(),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         activities <-
           call(context, :normalize_presence_activities, [presence_payload["activities"]]),
         ttl_ms <- call(context, :parse_int, [presence_payload["ttl_ms"], nil]),
         :ok <-
           apply_scoped_presence_update(
             data,
             remote_domain,
             remote_actor_id,
             status,
             activities,
             updated_at,
             ttl_ms,
             context
           ) do
      :ok
    else
      false -> :ok
      error -> normalize_event_error(error)
    end
  end

  defp apply_scoped_presence_update(
         data,
         remote_domain,
         remote_actor_id,
         status,
         activities,
         updated_at,
         ttl_ms,
         context
       ) do
    if room_scoped_presence_payload?(data) do
      with {:ok, _server, channel} <-
             call(context, :resolve_channel_event_context, [data, remote_domain]),
           :ok <-
             call(context, :ensure_remote_actor_membership, [
               channel,
               remote_actor_id,
               remote_domain,
               :read
             ]),
           {:ok, _presence_state} <-
             call(context, :upsert_room_presence_state, [
               channel.id,
               remote_actor_id,
               status,
               activities,
               updated_at,
               remote_domain,
               ttl_ms
             ]) do
        call(context, :maybe_broadcast_room_presence_update, [
          channel.id,
          remote_actor_id,
          status,
          activities,
          updated_at
        ])
      end
    else
      subscriber_user_ids = call(context, :local_presence_subscriber_user_ids, [remote_actor_id])

      with true <- subscriber_user_ids != [],
           {:ok, _presence_state} <-
             call(context, :upsert_account_presence_state, [
               remote_actor_id,
               status,
               activities,
               updated_at,
               remote_domain,
               ttl_ms
             ]),
           server_ids <- call(context, :server_ids_for_remote_actor, [remote_actor_id]) do
        call(context, :maybe_broadcast_presence_update, [
          subscriber_user_ids,
          server_ids,
          remote_actor_id,
          status,
          activities,
          updated_at
        ])
      end
    end
  end

  defp apply_typing_start(data, remote_domain, context) do
    with %{} = actor_payload <- data["actor"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         :ok <-
           call(context, :maybe_broadcast_remote_typing_started, [
             channel.id,
             remote_actor_id
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_typing_stop(data, remote_domain, context) do
    with %{} = actor_payload <- data["actor"],
         {:ok, _server, channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           call(context, :ensure_remote_actor_membership, [
             channel,
             remote_actor_id,
             remote_domain,
             :write
           ]),
         :ok <-
           call(context, :maybe_broadcast_remote_typing_stopped, [
             channel.id,
             remote_actor_id
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  defp apply_invite_target_projection(
         mirror_channel,
         target_payload,
         remote_domain,
         remote_actor_id,
         role,
         state,
         invite_payload,
         context
       ) do
    invited_at = call(context, :parse_datetime, [invite_payload["invited_at"]])

    updated_at =
      call(context, :parse_datetime, [invite_payload["updated_at"]]) || DateTime.utc_now()

    case resolve_local_user_from_actor_payload(target_payload) do
      %User{} = local_user ->
        with :ok <- apply_local_invite_state(mirror_channel, local_user, role, state),
             {:ok, membership_state} <-
               maybe_local_membership_state_for_invite(
                 mirror_channel,
                 local_user,
                 role,
                 state,
                 invited_at,
                 updated_at,
                 actor_payload: get_actor_payload(invite_payload),
                 actor_remote_id: remote_actor_id,
                 metadata: invite_payload["metadata"] || %{}
               ) do
          maybe_broadcast_optional_membership_state(
            mirror_channel.id,
            membership_state,
            context
          )
        end

      nil ->
        with {:ok, remote_target_actor_id} <-
               call(context, :resolve_or_create_remote_actor_id, [target_payload, remote_domain]),
             {:ok, membership_state} <-
               call(context, :upsert_membership_state, [
                 mirror_channel.id,
                 remote_target_actor_id,
                 remote_domain,
                 role,
                 call(context, :invite_membership_state, [state]),
                 invited_at,
                 updated_at,
                 %{
                   "governance_event" => "invite.upsert",
                   "invite_state" => state,
                   "actor" => get_actor_payload(invite_payload),
                   "actor_remote_id" => remote_actor_id,
                   "metadata" => invite_payload["metadata"] || %{}
                 }
               ]) do
          call(context, :maybe_broadcast_membership_state, [mirror_channel.id, membership_state])
        end
    end
  end

  defp apply_ban_target_projection(
         mirror_channel,
         target_payload,
         remote_domain,
         remote_actor_id,
         state,
         ban_payload,
         context
       ) do
    banned_at = call(context, :parse_datetime, [ban_payload["banned_at"]])
    updated_at = call(context, :parse_datetime, [ban_payload["updated_at"]]) || DateTime.utc_now()

    case resolve_local_user_from_actor_payload(target_payload) do
      %User{} = local_user ->
        with :ok <-
               apply_local_ban_state(
                 mirror_channel,
                 local_user,
                 state,
                 ban_payload,
                 remote_domain
               ),
             {:ok, membership_state} <-
               maybe_local_membership_state_for_ban(
                 mirror_channel,
                 local_user,
                 state,
                 banned_at,
                 updated_at,
                 actor_payload: get_actor_payload(ban_payload),
                 actor_remote_id: remote_actor_id,
                 reason: ban_payload["reason"],
                 expires_at: ban_payload["expires_at"],
                 metadata: ban_payload["metadata"] || %{}
               ) do
          maybe_broadcast_optional_membership_state(
            mirror_channel.id,
            membership_state,
            context
          )
        end

      nil ->
        with {:ok, remote_target_actor_id} <-
               call(context, :resolve_or_create_remote_actor_id, [target_payload, remote_domain]),
             {:ok, membership_state} <-
               call(context, :upsert_membership_state, [
                 mirror_channel.id,
                 remote_target_actor_id,
                 remote_domain,
                 "member",
                 call(context, :ban_membership_state, [state]),
                 banned_at,
                 updated_at,
                 %{
                   "governance_event" => "ban.upsert",
                   "ban_state" => state,
                   "reason" => ban_payload["reason"],
                   "expires_at" => ban_payload["expires_at"],
                   "actor" => get_actor_payload(ban_payload),
                   "actor_remote_id" => remote_actor_id,
                   "metadata" => ban_payload["metadata"] || %{}
                 }
               ]) do
          call(context, :maybe_broadcast_membership_state, [mirror_channel.id, membership_state])
        end
    end
  end

  defp apply_membership_projection(
         server,
         channel,
         remote_actor_id,
         remote_domain,
         role,
         state,
         membership_payload,
         context
       ) do
    joined_at = call(context, :parse_datetime, [membership_payload["joined_at"]])

    updated_at =
      call(context, :parse_datetime, [membership_payload["updated_at"]]) || DateTime.utc_now()

    metadata = membership_payload["metadata"] || %{}

    if server.is_federated_mirror do
      apply_mirrored_membership_projection(
        server,
        channel,
        remote_actor_id,
        remote_domain,
        role,
        state,
        joined_at,
        updated_at,
        metadata,
        membership_payload,
        context
      )
    else
      apply_authoritative_membership_projection(
        channel,
        remote_actor_id,
        role,
        state,
        joined_at,
        updated_at,
        metadata,
        membership_payload,
        context
      )
    end
  end

  defp apply_mirrored_membership_projection(
         %Server{} = server,
         %Conversation{} = channel,
         remote_actor_id,
         remote_domain,
         role,
         state,
         joined_at,
         updated_at,
         metadata,
         membership_payload,
         context
       ) do
    if normalize_domain(remote_domain) == normalize_domain(server.origin_domain) do
      with {:ok, membership_state} <-
             call(context, :upsert_membership_state, [
               channel.id,
               remote_actor_id,
               remote_domain,
               role,
               state,
               joined_at,
               updated_at,
               metadata
             ]) do
        call(context, :maybe_broadcast_membership_state, [channel.id, membership_state])
      end
    else
      apply_participant_membership_projection(
        channel,
        remote_actor_id,
        remote_domain,
        role,
        state,
        joined_at,
        updated_at,
        metadata,
        membership_payload,
        context
      )
    end
  end

  defp apply_participant_membership_projection(
         %Conversation{} = channel,
         remote_actor_id,
         remote_domain,
         role,
         state,
         joined_at,
         updated_at,
         metadata,
         membership_payload,
         context
       ) do
    actor_payload = membership_payload["actor"] || %{}

    existing_state =
      Repo.get_by(FederationMembershipState,
        conversation_id: channel.id,
        remote_actor_id: remote_actor_id
      )

    cond do
      role not in ["member", "readonly"] ->
        {:error, :invalid_event_payload}

      state not in ["active", "invited", "left"] ->
        {:error, :invalid_event_payload}

      existing_state && existing_state.state == "banned" ->
        :ok

      true ->
        with {:ok, membership_state} <-
               call(context, :upsert_membership_state, [
                 channel.id,
                 remote_actor_id,
                 actor_origin_domain(actor_payload) || remote_domain,
                 role,
                 state,
                 joined_at,
                 updated_at,
                 metadata
               ]) do
          call(context, :maybe_broadcast_membership_state, [channel.id, membership_state])
        end
    end
  end

  defp apply_authoritative_membership_projection(
         %Conversation{} = channel,
         remote_actor_id,
         role,
         state,
         joined_at,
         updated_at,
         metadata,
         membership_payload,
         context
       ) do
    actor_payload = membership_payload["actor"] || %{}

    existing_state =
      Repo.get_by(FederationMembershipState,
        conversation_id: channel.id,
        remote_actor_id: remote_actor_id
      )

    actor_uri = actor_uri(actor_payload)
    invite_state = invite_state_for_actor(channel.id, actor_uri)

    cond do
      role not in ["member", "readonly"] ->
        {:error, :invalid_event_payload}

      state == "banned" ->
        {:error, :invalid_event_payload}

      existing_state && existing_state.state == "banned" ->
        publish_join_decision(channel, actor_payload, "declined", role, %{"reason" => "banned"})
        :ok

      state == "active" and allowed_remote_activation?(existing_state, invite_state) ->
        with {:ok, membership_state} <-
               call(context, :upsert_membership_state, [
                 channel.id,
                 remote_actor_id,
                 actor_origin_domain(actor_payload),
                 role,
                 "active",
                 joined_at,
                 updated_at,
                 metadata
               ]) do
          call(context, :maybe_broadcast_membership_state, [channel.id, membership_state])
        end

      state == "active" ->
        {:error, :not_authorized_for_room}

      state == "left" ->
        with {:ok, membership_state} <-
               call(context, :upsert_membership_state, [
                 channel.id,
                 remote_actor_id,
                 actor_origin_domain(actor_payload),
                 role,
                 "left",
                 joined_at,
                 updated_at,
                 metadata
               ]) do
          call(context, :maybe_broadcast_membership_state, [channel.id, membership_state])
        end

      state == "invited" ->
        handle_remote_join_request(
          channel,
          remote_actor_id,
          actor_payload,
          role,
          joined_at,
          updated_at,
          metadata,
          context
        )

      true ->
        {:error, :invalid_event_payload}
    end
  end

  defp handle_remote_join_request(
         %Conversation{} = channel,
         remote_actor_id,
         actor_payload,
         role,
         joined_at,
         updated_at,
         metadata,
         context
       ) do
    decision =
      cond do
        remote_actor_banned?(channel.id, remote_actor_id) -> {"declined", %{"reason" => "banned"}}
        channel.is_public != true -> {"pending", %{"reason" => "invite_only"}}
        channel.approval_mode_enabled == true -> {"pending", %{"reason" => "approval_required"}}
        true -> {"accepted", %{}}
      end

    {invite_state, decision_metadata} = decision
    membership_state_value = if invite_state == "accepted", do: "active", else: "invited"
    joined_at_value = if invite_state == "accepted", do: joined_at, else: nil

    with {:ok, membership_state} <-
           call(context, :upsert_membership_state, [
             channel.id,
             remote_actor_id,
             actor_origin_domain(actor_payload),
             role,
             membership_state_value,
             joined_at_value,
             updated_at,
             Map.merge(metadata, %{"join_request" => true})
           ]),
         :ok <- call(context, :maybe_broadcast_membership_state, [channel.id, membership_state]) do
      publish_join_decision(channel, actor_payload, invite_state, role, decision_metadata)
      :ok
    end
  end

  defp apply_local_invite_state(%Conversation{} = mirror_channel, local_user, role, "accepted") do
    ensure_local_mirror_server_membership(mirror_channel, local_user.id)

    case Elektrine.Messaging.Conversations.add_member_to_conversation_without_federation(
           mirror_channel.id,
           local_user.id,
           role
         ) do
      {:ok, _member} -> :ok
      {:error, :already_member} -> :ok
      other -> other
    end
  end

  defp apply_local_invite_state(_mirror_channel, _local_user, _role, state)
       when state in ["pending", "declined", "revoked"],
       do: :ok

  defp apply_local_invite_state(_mirror_channel, _local_user, _role, _state),
    do: {:error, :invalid_event_payload}

  defp apply_local_ban_state(
         %Conversation{} = mirror_channel,
         local_user,
         "active",
         ban_payload,
         remote_domain
       ) do
    with :ok <- remove_local_banned_member(mirror_channel, local_user),
         {:ok, _ban} <-
           upsert_local_ban_projection(mirror_channel, local_user, ban_payload, remote_domain) do
      :ok
    end
  end

  defp apply_local_ban_state(
         %Conversation{} = mirror_channel,
         local_user,
         "lifted",
         ban_payload,
         remote_domain
       ) do
    delete_local_ban_projection(mirror_channel, local_user, ban_payload, remote_domain)
  end

  defp apply_local_ban_state(_mirror_channel, _local_user, _state, _ban_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp remove_local_banned_member(%Conversation{} = mirror_channel, local_user) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^mirror_channel.id and cm.user_id == ^local_user.id and
          is_nil(cm.left_at)
    )
    |> Repo.one()
    |> case do
      %ConversationMember{} = member ->
        member
        |> ConversationMember.remove_member_changeset()
        |> Repo.update()
        |> case do
          {:ok, _updated} ->
            refresh_local_member_count(mirror_channel.id)
            :ok

          error ->
            error
        end

      nil ->
        :ok
    end
  end

  defp remove_local_banned_member(_mirror_channel, _local_user), do: :ok

  defp upsert_local_ban_projection(
         %Conversation{} = mirror_channel,
         %User{} = local_user,
         ban_payload,
         remote_domain
       )
       when is_map(ban_payload) and is_binary(remote_domain) do
    actor_payload = get_actor_payload(ban_payload)
    actor_origin_domain = actor_origin_domain(actor_payload) || remote_domain

    attrs = %{
      conversation_id: mirror_channel.id,
      user_id: local_user.id,
      banned_by_id: nil,
      origin_domain: actor_origin_domain,
      actor_payload: actor_payload,
      metadata: ban_payload["metadata"] || %{},
      reason: ban_payload["reason"],
      expires_at: parse_optional_datetime(ban_payload["expires_at"]),
      banned_at_remote: parse_optional_datetime(ban_payload["banned_at"]),
      updated_at_remote: parse_optional_datetime(ban_payload["updated_at"]) || DateTime.utc_now()
    }

    %CommunityBan{}
    |> CommunityBan.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :banned_by_id,
           :origin_domain,
           :actor_payload,
           :metadata,
           :reason,
           :expires_at,
           :banned_at_remote,
           :updated_at_remote,
           :updated_at
         ]},
      conflict_target: [:conversation_id, :user_id]
    )
  end

  defp upsert_local_ban_projection(_mirror_channel, _local_user, _ban_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp delete_local_ban_projection(
         %Conversation{} = mirror_channel,
         %User{} = local_user,
         ban_payload,
         remote_domain
       )
       when is_map(ban_payload) and is_binary(remote_domain) do
    actor_payload = get_actor_payload(ban_payload)
    actor_origin_domain = actor_origin_domain(actor_payload) || remote_domain

    from(ban in CommunityBan,
      where: ban.conversation_id == ^mirror_channel.id and ban.user_id == ^local_user.id,
      where: ban.origin_domain == ^actor_origin_domain
    )
    |> Repo.delete_all()

    :ok
  end

  defp delete_local_ban_projection(_mirror_channel, _local_user, _ban_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp refresh_local_member_count(conversation_id) when is_integer(conversation_id) do
    count =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: count()
      )
      |> Repo.one()

    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [member_count: count])

    :ok
  end

  defp refresh_local_member_count(_conversation_id), do: :ok

  defp maybe_local_membership_state_for_invite(
         _mirror_channel,
         _local_user,
         _role,
         _state,
         _invited_at,
         _updated_at,
         _opts
       ),
       do: {:ok, nil}

  defp maybe_local_membership_state_for_ban(
         _mirror_channel,
         _local_user,
         _state,
         _banned_at,
         _updated_at,
         _opts
       ),
       do: {:ok, nil}

  defp maybe_broadcast_optional_membership_state(_conversation_id, nil, _context), do: :ok

  defp maybe_broadcast_optional_membership_state(conversation_id, membership_state, context) do
    call(context, :maybe_broadcast_membership_state, [conversation_id, membership_state])
  end

  defp ensure_local_mirror_server_membership(%Conversation{server_id: server_id}, user_id)
       when is_integer(server_id) and is_integer(user_id) do
    case Repo.get_by(ServerMember, server_id: server_id, user_id: user_id) do
      nil ->
        ServerMember.add_member_changeset(server_id, user_id, "member")
        |> Repo.insert()
        |> case do
          {:ok, _member} ->
            refresh_local_server_member_count(server_id)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      %ServerMember{left_at: nil} ->
        :ok

      %ServerMember{} = member ->
        member
        |> ServerMember.changeset(%{left_at: nil, joined_at: DateTime.utc_now(), role: "member"})
        |> Repo.update()
        |> case do
          {:ok, _updated} ->
            refresh_local_server_member_count(server_id)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ensure_local_mirror_server_membership(_mirror_channel, _user_id), do: :ok

  defp refresh_local_server_member_count(server_id) when is_integer(server_id) do
    count =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and is_nil(sm.left_at),
        select: count()
      )
      |> Repo.one()

    from(server in Elektrine.Messaging.Server, where: server.id == ^server_id)
    |> Repo.update_all(set: [member_count: count])

    :ok
  end

  defp refresh_local_server_member_count(_server_id), do: :ok

  defp resolve_local_user_from_actor_payload(actor_payload) when is_map(actor_payload) do
    uri = actor_uri(actor_payload)
    username = actor_payload["username"] || actor_payload[:username]
    domain = actor_payload["domain"] || actor_payload[:domain]

    cond do
      is_binary(uri) ->
        case ActivityPub.local_username_from_uri(uri) do
          {:ok, local_username} -> Accounts.get_user_by_username(local_username)
          _ -> nil
        end

      is_binary(username) and is_binary(domain) and
          String.downcase(domain) == Federation.local_domain() ->
        Accounts.get_user_by_username(username)

      true ->
        nil
    end
  end

  defp resolve_local_user_from_actor_payload(_actor_payload), do: nil

  defp publish_join_decision(%Conversation{} = channel, target_payload, state, role, metadata)
       when state in ["pending", "accepted", "declined", "revoked"] do
    case governance_actor_user_id(channel) do
      actor_user_id when is_integer(actor_user_id) ->
        Federation.publish_remote_invite_state(
          channel.id,
          target_payload,
          actor_user_id,
          state,
          role,
          metadata
        )

        :ok

      _ ->
        :ok
    end
  end

  defp governance_actor_user_id(%Conversation{creator_id: creator_id})
       when is_integer(creator_id),
       do: creator_id

  defp governance_actor_user_id(_channel), do: nil

  defp allowed_remote_activation?(%FederationMembershipState{state: "active"}, _invite_state),
    do: true

  defp allowed_remote_activation?(_membership_state, "accepted"), do: true
  defp allowed_remote_activation?(_membership_state, _invite_state), do: false

  defp invite_state_for_actor(conversation_id, actor_uri)
       when is_integer(conversation_id) and is_binary(actor_uri) do
    from(invite in Elektrine.Messaging.FederationInviteState,
      where: invite.conversation_id == ^conversation_id and invite.target_uri == ^actor_uri,
      select: invite.state,
      limit: 1
    )
    |> Repo.one()
  end

  defp invite_state_for_actor(_conversation_id, _actor_uri), do: nil

  defp remote_actor_banned?(conversation_id, remote_actor_id)
       when is_integer(conversation_id) and is_integer(remote_actor_id) do
    Repo.exists?(
      from(state in FederationMembershipState,
        where:
          state.conversation_id == ^conversation_id and
            state.remote_actor_id == ^remote_actor_id and
            state.state == "banned"
      )
    )
  end

  defp remote_actor_banned?(_conversation_id, _remote_actor_id), do: false

  defp actor_uri(actor_payload) when is_map(actor_payload) do
    value =
      actor_payload["uri"] || actor_payload[:uri] || actor_payload["id"] || actor_payload[:id]

    case value do
      uri when is_binary(uri) and uri != "" -> uri
      _ -> nil
    end
  end

  defp actor_uri(_actor_payload), do: nil

  defp actor_origin_domain(actor_payload) when is_map(actor_payload) do
    case actor_payload["domain"] || actor_payload[:domain] do
      domain when is_binary(domain) and domain != "" ->
        String.downcase(domain)

      _ ->
        actor_payload
        |> actor_uri()
        |> case do
          uri when is_binary(uri) ->
            case URI.parse(uri) do
              %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
              _ -> Federation.local_domain()
            end

          _ ->
            Federation.local_domain()
        end
    end
  end

  defp actor_origin_domain(_actor_payload), do: Federation.local_domain()

  defp authorize_governance_event(
         data,
         remote_domain,
         mirror_channel,
         remote_actor_id,
         action,
         context
       )
       when is_map(data) and is_binary(remote_domain) and is_map(mirror_channel) and
              is_integer(remote_actor_id) and is_atom(action) and is_map(context) do
    case call(context, :ensure_authoritative_channel_event_context, [data, remote_domain]) do
      {:ok, _server, _channel} ->
        :ok

      _ ->
        call(context, :ensure_remote_actor_governance_permission, [
          mirror_channel,
          remote_actor_id,
          action,
          %{remote_actor_id: remote_actor_id}
        ])
    end
  end

  defp authorize_governance_event(
         _data,
         _remote_domain,
         _mirror_channel,
         _remote_actor_id,
         _action,
         _context
       ),
       do: {:error, :not_authorized_for_room}

  defp get_actor_payload(payload) when is_map(payload), do: payload["actor"] || %{}

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_domain(_value), do: nil

  defp normalize_event_error({:error, _reason} = error), do: error
  defp normalize_event_error(:ok), do: :ok
  defp normalize_event_error(_error), do: {:error, :invalid_event_payload}

  defp room_scoped_presence_payload?(data) when is_map(data) do
    is_binary(get_in(data, ["refs", "channel_id"])) or is_binary(get_in(data, ["channel", "id"]))
  end

  defp room_scoped_presence_payload?(_data), do: false

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
