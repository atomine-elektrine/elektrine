defmodule Elektrine.Messaging.Federation do
  @moduledoc "Compatibility facade for modular Arblarg federation APIs."

  alias Elektrine.Messaging.Federation.{
    Egress,
    Errors,
    Ingress,
    Maintenance,
    Peers,
    PublicDiscovery,
    RequestAuth,
    Runtime
  }

  defdelegate enabled?, to: Peers
  defdelegate peers, to: Peers
  defdelegate incoming_peer(domain), to: Peers
  defdelegate outgoing_peers, to: Peers
  defdelegate outgoing_peer(domain), to: Peers
  defdelegate local_domain, to: Peers
  defdelegate list_server_presence_states(server_id), to: Peers
  defdelegate list_peer_controls, to: Peers
  defdelegate paginate_peer_controls(search_query, page, per_page), to: Peers
  defdelegate upsert_peer_policy(domain, attrs), to: Peers
  defdelegate upsert_peer_policy(domain, attrs, updated_by_id), to: Peers
  defdelegate clear_peer_policy(domain), to: Peers
  defdelegate block_peer_domain(domain), to: Peers
  defdelegate block_peer_domain(domain, reason), to: Peers
  defdelegate block_peer_domain(domain, reason, updated_by_id), to: Peers
  defdelegate unblock_peer_domain(domain), to: Peers
  defdelegate unblock_peer_domain(domain, updated_by_id), to: Peers

  defdelegate discover_peer(domain), to: PublicDiscovery
  defdelegate discover_peer(domain, opts), to: PublicDiscovery
  defdelegate refresh_peer_discovery(domain), to: PublicDiscovery
  defdelegate local_discovery_document(), to: PublicDiscovery
  defdelegate local_discovery_document(version), to: PublicDiscovery
  defdelegate arblarg_profiles_document(), to: PublicDiscovery
  defdelegate arblarg_profiles_document(version), to: PublicDiscovery
  defdelegate discovery_limits_for_transport, to: PublicDiscovery
  defdelegate transport_profiles_for_transport, to: PublicDiscovery
  defdelegate session_flow_control_for_transport, to: PublicDiscovery

  def signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    RequestAuth.signature_payload(
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id
    )
  end

  defdelegate body_digest(body), to: RequestAuth
  defdelegate sign_payload(payload, signing_material), to: RequestAuth
  defdelegate valid_timestamp?(timestamp), to: RequestAuth
  defdelegate verify_signature(a, b, c, d, e, f, g), to: RequestAuth
  defdelegate verify_signature(a, b, c, d, e, f, g, h), to: RequestAuth
  defdelegate verify_signature(a, b, c, d, e, f, g, h, i), to: RequestAuth
  defdelegate verify_signature(a, b, c, d, e, f, g, h, i, j), to: RequestAuth

  def signed_headers(peer, method, request_path, query_string \\ "", body \\ "") do
    RequestAuth.signed_headers(peer, method, request_path, query_string, body)
  end

  defdelegate request_replay_nonce(a, b, c, d, e, f, g, h, i), to: RequestAuth
  defdelegate claim_request_nonce(a, b, c, d, e, f, g, h, i), to: RequestAuth

  def build_server_snapshot(server_id, opts \\ []) do
    Ingress.build_server_snapshot(server_id, opts)
  end

  defdelegate import_server_snapshot(payload, remote_domain), to: Ingress
  defdelegate receive_event(payload, remote_domain), to: Ingress
  defdelegate receive_event_batch(payload, remote_domain), to: Ingress
  defdelegate receive_ephemeral_batch(payload, remote_domain), to: Ingress
  defdelegate receive_session_stream_batch(payload, remote_domain), to: Ingress
  defdelegate receive_session_stream_batch(payload, remote_domain, frame_delivery_id), to: Ingress
  defdelegate receive_session_ephemeral_batch(payload, remote_domain), to: Ingress

  defdelegate receive_session_ephemeral_batch(payload, remote_domain, frame_delivery_id),
    to: Ingress

  defdelegate export_stream_events(stream_id), to: Ingress
  defdelegate export_stream_events(stream_id, opts), to: Ingress
  defdelegate recover_sequence_gap(payload, remote_domain), to: Ingress
  defdelegate refresh_mirror_server_snapshot(server), to: Ingress

  defdelegate push_server_snapshot(server_id), to: Egress
  defdelegate publish_server_upsert(server_id), to: Egress
  defdelegate publish_message_created(message), to: Egress
  defdelegate publish_dm_message_created(message), to: Egress
  defdelegate publish_dm_message_created(message, remote_handle), to: Egress
  defdelegate publish_message_updated(message), to: Egress
  defdelegate publish_message_deleted(message), to: Egress
  defdelegate publish_reaction_added(message, reaction), to: Egress
  defdelegate publish_reaction_removed(message, user_id, emoji), to: Egress

  def publish_read_cursor(conversation_id, user_id, message_id, read_at \\ DateTime.utc_now()) do
    Egress.publish_read_cursor(conversation_id, user_id, message_id, read_at)
  end

  def publish_read_receipt(conversation_id, user_id, message_id, read_at \\ DateTime.utc_now()) do
    Egress.publish_read_receipt(conversation_id, user_id, message_id, read_at)
  end

  defdelegate publish_typing_started(conversation_id, user_id), to: Egress
  defdelegate publish_typing_stopped(conversation_id, user_id), to: Egress

  def publish_presence_update(server_id, user_id, status, activities \\ []) do
    Egress.publish_presence_update(server_id, user_id, status, activities)
  end

  def publish_user_presence_update(user_id, status, activities \\ []) do
    Egress.publish_user_presence_update(user_id, status, activities)
  end

  def publish_membership_state(conversation_id, user_id, state, role \\ "member") do
    Egress.publish_membership_state(conversation_id, user_id, state, role)
  end

  def publish_invite_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state \\ "pending",
        role \\ "member",
        metadata \\ %{}
      ) do
    Egress.publish_invite_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      role,
      metadata
    )
  end

  def publish_ban_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state \\ "active",
        reason \\ nil,
        expires_at \\ nil,
        metadata \\ %{}
      ) do
    Egress.publish_ban_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      reason,
      expires_at,
      metadata
    )
  end

  defdelegate submit_mirror_message_created(message), to: Egress
  defdelegate submit_mirror_message_updated(message), to: Egress
  defdelegate submit_mirror_message_deleted(message), to: Egress
  defdelegate submit_mirror_reaction_added(message, reaction), to: Egress
  defdelegate submit_mirror_reaction_removed(message, user_id, emoji), to: Egress
  defdelegate maybe_push_for_conversation(conversation_id), to: Egress
  defdelegate maybe_push_for_server(server_id), to: Egress
  defdelegate process_outbox_event(outbox_event_id), to: Egress

  def enqueue_due_outbox_events(limit \\ 500) do
    Egress.enqueue_due_outbox_events(limit)
  end

  def run_retention do
    Maintenance.run_retention(Runtime.federation_config())
  end

  defdelegate error_code(reason), to: Errors
  defdelegate error_reason(code), to: Errors
end
