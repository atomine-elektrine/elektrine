defmodule Elektrine.Messaging.Federation.Contexts do
  @moduledoc false

  alias Elektrine.Messaging.Federation.{
    Actors,
    Attachments,
    Builders,
    Delivery,
    DirectMessageState,
    Dispatch,
    EventTracking,
    MirrorBroadcasts,
    Mirrors,
    Runtime,
    State,
    Transport
  }

  def publisher(options) when is_map(options) do
    builder_context = fetch(options, :builder_context)
    dispatch_context = fetch(options, :dispatch_context)
    state_context = fetch(options, :state_context)
    mirror_broadcast_context = fetch(options, :mirror_broadcast_context)

    %{
      enabled?: fetch(options, :enabled?),
      build_server_snapshot: fetch(options, :build_server_snapshot),
      build_server_snapshot_for_peer: fetch(options, :build_server_snapshot_for_peer),
      outgoing_peers: fetch(options, :outgoing_peers),
      push_snapshot_to_peer: fetch(options, :push_snapshot_to_peer),
      build_server_upsert_event: fn server_id ->
        Builders.build_server_upsert_event(server_id, builder_context.())
      end,
      build_message_created_event: fn message ->
        Builders.build_message_created_event(message, builder_context.())
      end,
      build_dm_message_created_event: fn message, remote_handle ->
        Builders.build_dm_message_created_event(message, remote_handle, builder_context.())
      end,
      build_dm_call_invite_event: fn session_id ->
        Builders.build_dm_call_invite_event(session_id, builder_context.())
      end,
      build_dm_call_accept_event: fn session_id ->
        Builders.build_dm_call_accept_event(session_id, builder_context.())
      end,
      build_dm_call_reject_event: fn session_id ->
        Builders.build_dm_call_reject_event(session_id, builder_context.())
      end,
      build_dm_call_end_event: fn session_id ->
        Builders.build_dm_call_end_event(session_id, builder_context.())
      end,
      build_dm_call_signal_ephemeral_item: fn session_id, actor_user_id, kind, signal_payload ->
        Builders.build_dm_call_signal_ephemeral_item(
          session_id,
          actor_user_id,
          kind,
          signal_payload,
          builder_context.()
        )
      end,
      build_message_updated_event: fn message ->
        Builders.build_message_updated_event(message, builder_context.())
      end,
      build_message_deleted_event: fn message ->
        Builders.build_message_deleted_event(message, builder_context.())
      end,
      build_reaction_added_event: fn message, reaction ->
        Builders.build_reaction_added_event(message, reaction, builder_context.())
      end,
      build_reaction_removed_event: fn message, user_id, emoji ->
        Builders.build_reaction_removed_event(message, user_id, emoji, builder_context.())
      end,
      build_read_cursor_event: fn conversation_id, user_id, message_id, read_at ->
        Builders.build_read_cursor_event(
          conversation_id,
          user_id,
          message_id,
          read_at,
          builder_context.()
        )
      end,
      build_typing_ephemeral_item: fn conversation_id, user_id, mode ->
        Builders.build_typing_ephemeral_item(conversation_id, user_id, mode, builder_context.())
      end,
      build_presence_ephemeral_item: fn user_id, status, activities ->
        Builders.build_presence_ephemeral_item(
          user_id,
          status,
          activities,
          builder_context.()
        )
      end,
      build_extension_event: fn conversation_id, actor_user_id, event_type, payload ->
        Builders.build_extension_event(
          conversation_id,
          actor_user_id,
          event_type,
          payload,
          builder_context.()
        )
      end,
      build_membership_upsert_event: fn conversation_id, user_id, state, role ->
        Builders.build_membership_upsert_event(
          conversation_id,
          user_id,
          state,
          role,
          builder_context.()
        )
      end,
      build_invite_upsert_event: fn conversation_id,
                                    target_user_id,
                                    actor_user_id,
                                    state,
                                    role,
                                    metadata ->
        Builders.build_invite_upsert_event(
          conversation_id,
          target_user_id,
          actor_user_id,
          state,
          role,
          metadata,
          builder_context.()
        )
      end,
      build_invite_upsert_event_for_target_payload: fn conversation_id,
                                                       target_payload,
                                                       actor_user_id,
                                                       state,
                                                       role,
                                                       metadata ->
        Builders.build_invite_upsert_event_for_target_payload(
          conversation_id,
          target_payload,
          actor_user_id,
          state,
          role,
          metadata,
          builder_context.()
        )
      end,
      build_ban_upsert_event: fn conversation_id,
                                 target_user_id,
                                 actor_user_id,
                                 state,
                                 reason,
                                 expires_at,
                                 metadata ->
        Builders.build_ban_upsert_event(
          conversation_id,
          target_user_id,
          actor_user_id,
          state,
          reason,
          expires_at,
          metadata,
          builder_context.()
        )
      end,
      enqueue_outbox_event: fn event, target_domains ->
        Dispatch.enqueue_outbox_event(event, target_domains, dispatch_context.())
      end,
      resolve_outbound_dm_handle: &DirectMessageState.resolve_outbound_dm_handle/2,
      normalize_remote_dm_handle: &DirectMessageState.normalize_remote_dm_handle/1,
      outgoing_peer: fetch(options, :outgoing_peer),
      fanout_ephemeral_batch: fn items, domains ->
        Dispatch.fanout_ephemeral_batch(items, domains, dispatch_context.())
      end,
      build_room_presence_ephemeral_item: fn conversation_id, user_id, status, activities ->
        Builders.build_room_presence_ephemeral_item(
          conversation_id,
          user_id,
          status,
          activities,
          builder_context.()
        )
      end,
      presence_subscriber_domains_for_local_user:
        &State.local_presence_subscriber_domains_for_user/1,
      active_server_ids_for_user: &Builders.active_server_ids_for_user/1,
      persist_local_invite_projection: fn conversation_id,
                                          target_user_id,
                                          actor_user_id,
                                          state,
                                          role,
                                          metadata ->
        State.persist_local_invite_projection(
          conversation_id,
          target_user_id,
          actor_user_id,
          state,
          role,
          metadata,
          state_context.()
        )
      end,
      persist_local_extension_projection: fn conversation_id, event_type, payload ->
        State.persist_local_extension_projection(
          conversation_id,
          event_type,
          payload,
          state_context.()
        )
      end,
      publish_latest_message_event: fn conversation_id ->
        MirrorBroadcasts.publish_latest_message_event(
          conversation_id,
          mirror_broadcast_context.()
        )
      end,
      get_chat_message: fetch(options, :get_chat_message)
    }
  end

  def builder(options) when is_map(options) do
    %{
      local_domain: &Runtime.local_domain/0,
      local_event_signing_material: &Runtime.local_event_signing_material/0,
      outgoing_peers: fetch(options, :outgoing_peers),
      maybe_iso8601: fetch(options, :maybe_iso8601),
      normalize_optional_string: fetch(options, :normalize_optional_string),
      presence_ttl_seconds: &Runtime.presence_ttl_seconds/0
    }
  end

  def delivery(options) when is_map(options) do
    builder_context = fetch(options, :builder_context)

    %{
      successful_delivery_statuses: fetch(options, :successful_delivery_statuses),
      outgoing_peer: fetch(options, :outgoing_peer),
      peer_batch_limit: fn peer ->
        Transport.peer_batch_limit(peer, Runtime.delivery_batch_size())
      end,
      delivery_batch_size: &Runtime.delivery_batch_size/0,
      outbox_backoff_seconds: &Runtime.outbox_backoff_seconds/1,
      normalize_optional_string: fetch(options, :normalize_optional_string),
      transport_profiles_document: fetch(options, :transport_profiles_document),
      peer_supports: &Transport.peer_supports?/3,
      peer_configured: fn peer ->
        Map.get(peer, :discovered) != true and Map.get(peer, "discovered") != true
      end,
      outbound_session_websocket_url: &Runtime.outbound_session_websocket_url/1,
      outbound_events_batch_url: &Runtime.outbound_events_batch_url/1,
      outbound_ephemeral_url: &Runtime.outbound_ephemeral_url/1,
      outbound_events_url: &Runtime.outbound_events_url/1,
      signed_headers: fetch(options, :signed_headers),
      delivery_timeout_ms: &Runtime.delivery_timeout_ms/0,
      truncate: fetch(options, :truncate),
      delivery_concurrency: &Runtime.delivery_concurrency/0,
      ephemeral_stream_id: &Dispatch.ephemeral_stream_id/2,
      next_outbound_sequence: fetch(options, :next_outbound_sequence),
      event_envelope: fn event_type, stream_id, sequence, data ->
        Builders.event_envelope(event_type, stream_id, sequence, data, builder_context.())
      end
    }
  end

  def inbound(options) when is_map(options) do
    %{
      incoming_batch_limit: &Runtime.incoming_batch_limit/0,
      incoming_ephemeral_limit: &Runtime.incoming_ephemeral_limit/0,
      normalize_optional_string: fetch(options, :normalize_optional_string),
      parse_int: fetch(options, :parse_int),
      receive_event: fetch(options, :receive_event),
      recover_sequence_gap: fetch(options, :recover_sequence_gap),
      error_code: fetch(options, :error_code),
      validate_origin_bound_actors_in_event_data:
        fetch(options, :validate_origin_bound_actors_in_event_data),
      validate_origin_owned_identifiers_in_event_data:
        fetch(options, :validate_origin_owned_identifiers_in_event_data),
      apply_event: fetch(options, :apply_event)
    }
  end

  def validation(options) when is_map(options) do
    %{
      normalize_incoming_event_payload: fetch(options, :normalize_incoming_event_payload),
      incoming_peer: fetch(options, :incoming_peer),
      incoming_verification_materials_for_key_id:
        fetch(options, :incoming_verification_materials_for_key_id),
      event_server_id: fetch(options, :event_server_id),
      event_channel_id: fetch(options, :event_channel_id),
      snapshot_governance_entries: fetch(options, :snapshot_governance_entries),
      snapshot_channel_limit: &Runtime.snapshot_channel_limit/0,
      snapshot_message_limit: &Runtime.snapshot_message_limit/0,
      snapshot_governance_limit: &Runtime.snapshot_governance_limit/0,
      snapshot_signature_payload: fetch(options, :snapshot_signature_payload)
    }
  end

  def snapshot(options) when is_map(options) do
    %{
      parse_int: fetch(options, :parse_int),
      snapshot_channel_limit: &Runtime.snapshot_channel_limit/0,
      snapshot_message_limit: &Runtime.snapshot_message_limit/0,
      snapshot_governance_limit: &Runtime.snapshot_governance_limit/0,
      channel_payload: fetch(options, :channel_payload),
      message_payload: fetch(options, :message_payload),
      local_domain: &Runtime.local_domain/0,
      server_payload: fetch(options, :server_payload),
      event_refs_payload: fetch(options, :event_refs_payload),
      sender_payload: fetch(options, :sender_payload),
      format_created_at: fetch(options, :format_created_at),
      maybe_iso8601: fetch(options, :maybe_iso8601),
      normalize_optional_string: fetch(options, :normalize_optional_string),
      local_event_signing_material: &Runtime.local_event_signing_material/0,
      validate_snapshot_payload: fetch(options, :validate_snapshot_payload),
      upsert_mirror_server: &Mirrors.upsert_mirror_server/2,
      upsert_mirror_channels: fn server, channels ->
        Mirrors.upsert_mirror_channels(server, channels, mirror_data())
      end,
      upsert_mirror_messages: fn channel_map, messages, remote_domain ->
        Mirrors.upsert_mirror_messages(channel_map, messages, remote_domain, mirror_data())
      end,
      validate_snapshot_governance_payload: fetch(options, :validate_snapshot_governance_payload),
      apply_event: fetch(options, :apply_event),
      store_stream_position: &EventTracking.store_stream_position/3,
      outbound_sync_url: &Runtime.outbound_sync_url/1,
      signed_headers: fetch(options, :signed_headers),
      delivery_timeout_ms: &Runtime.delivery_timeout_ms/0,
      truncate: fetch(options, :truncate),
      peer_supports: &Transport.peer_supports?/3,
      peer_supports_event_type: &Transport.peer_supports_event_type?/2,
      outbound_session_websocket_url: &Runtime.outbound_session_websocket_url/1,
      outbound_snapshot_url: &Runtime.outbound_snapshot_url/2,
      infer_remote_server_id_from_federation_id:
        fetch(options, :infer_remote_server_id_from_federation_id),
      outgoing_peer: fetch(options, :outgoing_peer),
      incoming_peer: fetch(options, :incoming_peer),
      infer_remote_server_id: fetch(options, :infer_remote_server_id),
      receive_event: fetch(options, :receive_event),
      stream_replay_limit: &Runtime.stream_replay_limit/0,
      outbound_stream_events_url: &Runtime.outbound_stream_events_url/2,
      server_stream_id: fetch(options, :server_stream_id),
      channel_stream_id: fetch(options, :channel_stream_id)
    }
  end

  def mirror_data do
    %{
      normalize_message_attachments: &Attachments.normalize_message_attachments/1,
      attachment_storage_metadata: &Attachments.attachment_storage_metadata/1
    }
  end

  def actor(options) when is_map(options) do
    %{
      resolve_peer: fetch(options, :resolve_peer),
      incoming_verification_materials_for_key_id:
        fetch(options, :incoming_verification_materials_for_key_id)
    }
  end

  def direct_message_state do
    %{
      local_domain: &Runtime.local_domain/0,
      normalize_message_attachments: &Attachments.normalize_message_attachments/1,
      attachment_storage_metadata: &Attachments.attachment_storage_metadata/1,
      broadcast_conversation_event: &MirrorBroadcasts.broadcast_conversation_event/2
    }
  end

  def state do
    %{
      broadcast_conversation_event: &MirrorBroadcasts.broadcast_conversation_event/2,
      maybe_broadcast_mirror_message_created:
        &MirrorBroadcasts.maybe_broadcast_mirror_message_created/1,
      maybe_broadcast_mirror_message_updated:
        &MirrorBroadcasts.maybe_broadcast_mirror_message_updated/1,
      local_domain: &Runtime.local_domain/0,
      presence_ttl_seconds: &Runtime.presence_ttl_seconds/0
    }
  end

  def discovery(options) when is_map(options) do
    %{
      local_domain: &Runtime.local_domain/0,
      peers: fetch(options, :peers),
      federation_config: &Runtime.federation_config/0,
      delivery_timeout_ms: &Runtime.delivery_timeout_ms/0,
      allow_insecure_transport?: &Runtime.allow_insecure_transport?/0,
      discovery_ttl_seconds: &Runtime.discovery_ttl_seconds/0,
      discovery_stale_grace_seconds: &Runtime.discovery_stale_grace_seconds/0,
      truncate: fetch(options, :truncate),
      local_event_signing_material: &Runtime.local_event_signing_material/0
    }
  end

  def auth(options) when is_map(options) do
    %{
      local_domain: &Runtime.local_domain/0,
      local_event_signing_material: &Runtime.local_event_signing_material/0,
      replay_nonce_ttl_seconds: &Runtime.replay_nonce_ttl_seconds/0,
      normalize_optional_string: fetch(options, :normalize_optional_string),
      parse_int: fetch(options, :parse_int),
      discover_peer_force: fetch(options, :discover_peer_force)
    }
  end

  def dispatch(options) when is_map(options) do
    delivery_context = fetch(options, :delivery_context)

    %{
      outgoing_peers: fetch(options, :outgoing_peers),
      outgoing_peer: fetch(options, :outgoing_peer),
      outbox_max_attempts: &Runtime.outbox_max_attempts/0,
      outbox_partition_month: &Runtime.outbox_partition_month/1,
      peer_ephemeral_limit: fn peer ->
        Transport.peer_ephemeral_limit(peer, Runtime.incoming_ephemeral_limit())
      end,
      push_ephemeral_batch_to_peer: fn peer, items ->
        Delivery.push_ephemeral_batch_to_peer(peer, items, delivery_context.())
      end
    }
  end

  def mirror_broadcast(options) when is_map(options) do
    %{
      publish_message_created: fetch(options, :publish_message_created)
    }
  end

  def direct_message do
    %{
      resolve_local_dm_recipient: fn recipient_payload ->
        DirectMessageState.resolve_local_dm_recipient(recipient_payload, direct_message_state())
      end,
      resolve_local_dm_participant: &Elektrine.Messaging.Federation.VoiceCalls.resolve_local_dm_participant/1,
      resolve_remote_dm_sender: &DirectMessageState.resolve_remote_dm_sender/2,
      ensure_remote_dm_conversation: &DirectMessageState.ensure_remote_dm_conversation/2,
      upsert_remote_dm_message: fn conversation, message_payload, remote_domain, remote_sender ->
        DirectMessageState.upsert_remote_dm_message(
          conversation,
          message_payload,
          remote_domain,
          remote_sender,
          direct_message_state()
        )
      end,
      maybe_broadcast_remote_dm_message_created: fn conversation,
                                                    message,
                                                    local_user,
                                                    remote_sender ->
        DirectMessageState.maybe_broadcast_remote_dm_message_created(
          conversation,
          message,
          local_user,
          remote_sender,
          direct_message_state()
        )
      end,
      ensure_inbound_call_session:
        &Elektrine.Messaging.Federation.VoiceCalls.ensure_inbound_session/5,
      reject_inbound_call_invite:
        &Elektrine.Messaging.Federation.VoiceCalls.reject_inbound_invite/6,
      apply_remote_call_accept:
        &Elektrine.Messaging.Federation.VoiceCalls.apply_remote_accept/5,
      apply_remote_call_reject:
        &Elektrine.Messaging.Federation.VoiceCalls.apply_remote_reject/6,
      apply_remote_call_end:
        &Elektrine.Messaging.Federation.VoiceCalls.apply_remote_end/6,
      apply_remote_call_signal:
        &Elektrine.Messaging.Federation.VoiceCalls.apply_remote_signal/5
    }
  end

  def mirror_event(options) when is_map(options) do
    actor_context = fetch(options, :actor_context)

    %{
      upsert_mirror_server: &Mirrors.upsert_mirror_server/2,
      upsert_mirror_channels: fn server, channels ->
        Mirrors.upsert_mirror_channels(server, channels, mirror_data())
      end,
      ensure_channel_event_context: fn data, remote_domain ->
        Mirrors.ensure_channel_event_context(data, remote_domain, mirror_data())
      end,
      ensure_authoritative_channel_event_context: fn data, remote_domain ->
        Mirrors.ensure_authoritative_channel_event_context(data, remote_domain, mirror_data())
      end,
      resolve_channel_event_context: fn data, remote_domain ->
        Mirrors.resolve_channel_event_context(data, remote_domain, mirror_data())
      end,
      ensure_server_event_context: fn data, remote_domain ->
        Mirrors.ensure_server_event_context(data, remote_domain, mirror_data())
      end,
      upsert_mirror_message: fn channel, payload, remote_domain ->
        Mirrors.upsert_mirror_message(channel, payload, remote_domain, mirror_data())
      end,
      upsert_or_update_mirror_message: fn channel, payload, remote_domain ->
        Mirrors.upsert_or_update_mirror_message(channel, payload, remote_domain, mirror_data())
      end,
      soft_delete_mirror_message: &Mirrors.soft_delete_mirror_message/4,
      maybe_broadcast_mirror_message_created:
        &MirrorBroadcasts.maybe_broadcast_mirror_message_created/1,
      maybe_broadcast_mirror_message_updated:
        &MirrorBroadcasts.maybe_broadcast_mirror_message_updated/1,
      maybe_broadcast_mirror_message_deleted:
        &MirrorBroadcasts.maybe_broadcast_mirror_message_deleted/1,
      get_mirror_message: &Mirrors.get_mirror_message/2,
      ensure_remote_actor_membership: &Mirrors.ensure_remote_actor_membership/4,
      ensure_remote_actor_governance_permission:
        &Mirrors.ensure_remote_actor_governance_permission/4,
      ensure_remote_message_author: &Mirrors.ensure_remote_message_author/3,
      resolve_or_create_remote_actor_id: fn actor_payload, remote_domain ->
        Actors.resolve_or_create_remote_actor_id(actor_payload, remote_domain, actor_context.())
      end,
      add_mirror_reaction: &MirrorBroadcasts.add_mirror_reaction/3,
      remove_mirror_reaction: &MirrorBroadcasts.remove_mirror_reaction/3,
      maybe_broadcast_mirror_reaction_added:
        &MirrorBroadcasts.maybe_broadcast_mirror_reaction_added/2,
      maybe_broadcast_mirror_reaction_removed:
        &MirrorBroadcasts.maybe_broadcast_mirror_reaction_removed/4,
      parse_datetime: fetch(options, :parse_datetime),
      parse_int: fetch(options, :parse_int),
      upsert_remote_read_cursor: fn conversation_id,
                                    chat_message_id,
                                    remote_actor_id,
                                    remote_domain,
                                    read_at,
                                    read_through_sequence ->
        State.upsert_remote_read_cursor(
          conversation_id,
          chat_message_id,
          remote_actor_id,
          remote_domain,
          read_at,
          read_through_sequence,
          state()
        )
      end,
      maybe_broadcast_remote_read_cursor: fn conversation_id, chat_message_id, remote_actor_id ->
        State.maybe_broadcast_remote_read_cursor(
          conversation_id,
          chat_message_id,
          remote_actor_id,
          state()
        )
      end,
      upsert_membership_state: &State.upsert_membership_state/8,
      upsert_invite_state: &State.upsert_invite_state/9,
      invite_membership_state: &State.invite_membership_state/1,
      ban_membership_state: &State.ban_membership_state/1,
      maybe_broadcast_membership_state: fn conversation_id, membership_state ->
        State.maybe_broadcast_membership_state(conversation_id, membership_state, state())
      end,
      event_server_payload: &Mirrors.event_server_payload/1,
      normalize_presence_activities: &State.normalize_presence_activities/1,
      local_presence_subscriber_user_ids: &State.local_presence_subscriber_user_ids/1,
      server_ids_for_remote_actor: &State.server_ids_for_remote_actor/1,
      upsert_account_presence_state: fn remote_actor_id,
                                        status,
                                        activities,
                                        updated_at,
                                        remote_domain,
                                        ttl_ms ->
        State.upsert_account_presence_state(
          remote_actor_id,
          status,
          activities,
          updated_at,
          remote_domain,
          ttl_ms,
          state()
        )
      end,
      upsert_room_presence_state: fn conversation_id,
                                     remote_actor_id,
                                     status,
                                     activities,
                                     updated_at,
                                     remote_domain,
                                     ttl_ms ->
        State.upsert_room_presence_state(
          conversation_id,
          remote_actor_id,
          status,
          activities,
          updated_at,
          remote_domain,
          ttl_ms,
          state()
        )
      end,
      maybe_broadcast_presence_update: fn subscriber_user_ids,
                                          server_ids,
                                          remote_actor_id,
                                          status,
                                          activities,
                                          updated_at ->
        State.maybe_broadcast_presence_update(
          subscriber_user_ids,
          server_ids,
          remote_actor_id,
          status,
          activities,
          updated_at,
          state()
        )
      end,
      maybe_broadcast_room_presence_update: fn conversation_id,
                                               remote_actor_id,
                                               status,
                                               activities,
                                               updated_at ->
        State.maybe_broadcast_room_presence_update(
          conversation_id,
          remote_actor_id,
          status,
          activities,
          updated_at,
          state()
        )
      end,
      maybe_broadcast_remote_typing_started: fn conversation_id, remote_actor_id ->
        State.maybe_broadcast_remote_typing_started(conversation_id, remote_actor_id, state())
      end,
      maybe_broadcast_remote_typing_stopped: fn conversation_id, remote_actor_id ->
        State.maybe_broadcast_remote_typing_stopped(conversation_id, remote_actor_id, state())
      end
    }
  end

  def extension_event(options) when is_map(options) do
    actor_context = fetch(options, :actor_context)

    %{
      ensure_authoritative_channel_event_context: fn data, remote_domain ->
        Mirrors.ensure_authoritative_channel_event_context(data, remote_domain, mirror_data())
      end,
      resolve_channel_event_context: fn data, remote_domain ->
        Mirrors.resolve_channel_event_context(data, remote_domain, mirror_data())
      end,
      ensure_remote_actor_governance_permission:
        &Mirrors.ensure_remote_actor_governance_permission/4,
      resolve_or_create_remote_actor_id: fn actor_payload, remote_domain ->
        Actors.resolve_or_create_remote_actor_id(actor_payload, remote_domain, actor_context.())
      end,
      upsert_extension_projection: fn event_type,
                                      event_key,
                                      payload,
                                      remote_domain,
                                      server_id,
                                      conversation_id,
                                      occurred_at,
                                      status ->
        State.upsert_extension_projection(
          event_type,
          event_key,
          payload,
          remote_domain,
          server_id,
          conversation_id,
          occurred_at,
          status
        )
      end,
      upsert_extension_system_message: fn mirror_channel,
                                          event_type,
                                          event_key,
                                          content,
                                          metadata,
                                          remote_domain ->
        State.upsert_extension_system_message(
          mirror_channel,
          event_type,
          event_key,
          content,
          metadata,
          remote_domain,
          state()
        )
      end,
      parse_datetime: fetch(options, :parse_datetime)
    }
  end

  defp fetch(options, key) do
    Map.fetch!(options, key)
  end
end
