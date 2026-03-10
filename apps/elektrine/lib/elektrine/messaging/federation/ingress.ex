defmodule Elektrine.Messaging.Federation.Ingress do
  @moduledoc false

  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Messaging.{ArblargSDK, Server}
  alias Elektrine.Messaging.Federation.{
    Contexts,
    Errors,
    EventRouter,
    EventTracking,
    Inbound,
    Peers,
    RequestAuth,
    Snapshots,
    Validation
  }
  alias Elektrine.Repo

  def build_server_snapshot(server_id, opts \\ []) do
    Snapshots.build_server_snapshot(server_id, opts, snapshot_context())
  end

  def import_server_snapshot(payload, remote_domain) when is_binary(remote_domain) do
    import_server_snapshot(payload, remote_domain, snapshot_context())
  end

  def import_server_snapshot(payload, remote_domain, snapshot_context)
      when is_binary(remote_domain) do
    Snapshots.import_server_snapshot(payload, remote_domain, snapshot_context)
  end

  def receive_event(payload, remote_domain) when is_binary(remote_domain) do
    receive_event(payload, remote_domain, ingress_context())
  end

  def receive_event(payload, remote_domain, context) when is_binary(remote_domain) and is_map(context) do
    with :ok <- call(context, :validate_event_payload, [payload, remote_domain]) do
      payload = call(context, :normalize_incoming_event_payload, [payload])

      Repo.transaction(fn ->
        case call(context, :claim_event_id, [payload, remote_domain]) do
          :duplicate ->
            :duplicate

          :new ->
            case call(context, :check_sequence, [payload, remote_domain]) do
              :stale ->
                :stale

              :ok ->
                event_type = ArblargSDK.canonical_event_type(payload["event_type"])

                with :ok <-
                       call(context, :apply_event, [
                         event_type,
                         payload["payload"] || %{},
                         remote_domain
                       ]),
                     :ok <-
                       call(context, :store_stream_position, [
                         remote_domain,
                         payload["stream_id"],
                         payload["sequence"]
                       ]) do
                  :applied
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, result} when result in [:applied, :duplicate, :stale] -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def receive_event_batch(payload, remote_domain) when is_binary(remote_domain) do
    receive_event_batch(payload, remote_domain, ingress_context())
  end

  def receive_event_batch(payload, remote_domain, context) when is_binary(remote_domain) and is_map(context) do
    with {:ok, batch_id, events} <- call(context, :normalize_incoming_batch_payload, [payload]) do
      results =
        Enum.map(events, fn event ->
          call(context, :process_incoming_event_result, [event, remote_domain])
        end)

      {:ok, call(context, :batch_summary, [batch_id, results])}
    end
  end

  def receive_ephemeral_batch(payload, remote_domain) when is_binary(remote_domain) do
    receive_ephemeral_batch(payload, remote_domain, ingress_context())
  end

  def receive_ephemeral_batch(payload, remote_domain, context)
      when is_binary(remote_domain) and is_map(context) do
    with {:ok, batch_id, items} <-
           call(context, :normalize_incoming_ephemeral_payload, [payload]) do
      results =
        Enum.map(items, fn item ->
          call(context, :process_incoming_ephemeral_result, [item, remote_domain])
        end)

      {:ok, call(context, :batch_summary, [batch_id, results])}
    end
  end

  def receive_session_stream_batch(payload, remote_domain, frame_delivery_id \\ nil)

  def receive_session_stream_batch(payload, remote_domain, frame_delivery_id)
      when is_binary(remote_domain) do
    receive_session_stream_batch(payload, remote_domain, frame_delivery_id, ingress_context())
  end

  def receive_session_stream_batch(payload, remote_domain, frame_delivery_id, context)
      when is_binary(remote_domain) and is_map(context) do
    with {:ok, delivery_id, events} <-
           call(context, :normalize_session_stream_batch_payload, [
             payload,
             frame_delivery_id
           ]),
         results <-
           Enum.map(events, &call(context, :process_incoming_event_result, [&1, remote_domain])) do
      {:ok, call(context, :batch_summary, [delivery_id, results])}
    end
  end

  def receive_session_ephemeral_batch(payload, remote_domain, frame_delivery_id \\ nil)

  def receive_session_ephemeral_batch(payload, remote_domain, frame_delivery_id)
      when is_binary(remote_domain) do
    receive_session_ephemeral_batch(payload, remote_domain, frame_delivery_id, ingress_context())
  end

  def receive_session_ephemeral_batch(payload, remote_domain, frame_delivery_id, context)
      when is_binary(remote_domain) and is_map(context) do
    with {:ok, delivery_id, items} <-
           call(context, :normalize_session_ephemeral_batch_payload, [
             payload,
             frame_delivery_id
           ]),
         results <-
           Enum.map(items, &call(context, :process_incoming_ephemeral_result, [&1, remote_domain])) do
      {:ok, call(context, :batch_summary, [delivery_id, results])}
    end
  end

  def export_stream_events(stream_id, opts \\ [])

  def export_stream_events(stream_id, opts) when is_binary(stream_id) do
    export_stream_events(stream_id, opts, snapshot_context())
  end

  def export_stream_events(stream_id, opts, snapshot_context) when is_binary(stream_id) do
    Snapshots.export_stream_events(stream_id, opts, snapshot_context)
  end

  def recover_sequence_gap(payload, remote_domain) when is_binary(remote_domain) do
    recover_sequence_gap(payload, remote_domain, snapshot_context())
  end

  def recover_sequence_gap(payload, remote_domain, snapshot_context) when is_binary(remote_domain) do
    Snapshots.recover_sequence_gap(payload, remote_domain, snapshot_context)
  end

  def refresh_mirror_server_snapshot(%Server{} = server) do
    refresh_mirror_server_snapshot(server, snapshot_context())
  end

  def refresh_mirror_server_snapshot(%Server{} = server, snapshot_context) do
    Snapshots.refresh_mirror_server_snapshot(server, snapshot_context)
  end

  def refresh_mirror_server_snapshot(_server, _snapshot_context), do: {:error, :not_federated_mirror}

  def push_snapshot_to_peer(peer, snapshot) do
    Snapshots.push_snapshot_to_peer(peer, snapshot, snapshot_context())
  end

  def push_snapshot_to_peer(peer, snapshot, context) when is_map(context) do
    Snapshots.push_snapshot_to_peer(peer, snapshot, context)
  end

  defp validate_snapshot_governance_payload(event_type, payload, remote_domain)
       when is_binary(event_type) and is_map(payload) and is_binary(remote_domain) do
    Validation.validate_snapshot_governance_payload(
      event_type,
      payload,
      remote_domain,
      validation_context()
    )
  end

  defp validate_snapshot_governance_payload(_event_type, _payload, _remote_domain),
    do: {:error, :invalid_snapshot_governance}

  defp snapshot_governance_entries(governance) do
    Snapshots.snapshot_governance_entries(governance, snapshot_context())
  end

  defp validate_snapshot_payload(payload, remote_domain) do
    Validation.validate_snapshot_payload(payload, remote_domain, validation_context())
  end

  defp validate_event_payload(payload, remote_domain) do
    Validation.validate_event_payload(payload, remote_domain, validation_context())
  end

  defp validate_origin_bound_actors_in_event_data(event_type, data, remote_domain) do
    Validation.validate_origin_bound_actors_in_event_data(
      event_type,
      data,
      remote_domain,
      validation_context()
    )
  end

  defp validate_origin_owned_identifiers_in_event_data(event_type, data, remote_domain) do
    Validation.validate_origin_owned_identifiers_in_event_data(
      event_type,
      data,
      remote_domain,
      validation_context()
    )
  end

  defp validation_context do
    Contexts.validation(%{
      normalize_incoming_event_payload: &EventRouter.normalize_incoming_event_payload/1,
      incoming_peer: &Peers.incoming_peer/1,
      incoming_verification_materials_for_key_id:
        &RequestAuth.incoming_verification_materials_for_key_id/2,
      event_server_id: &EventRouter.event_server_id/1,
      event_channel_id: &EventRouter.event_channel_id/1,
      snapshot_governance_entries: &snapshot_governance_entries/1,
      snapshot_signature_payload: &Snapshots.snapshot_signature_payload/1
    })
  end

  defp snapshot_context do
    Contexts.snapshot(%{
      parse_int: &parse_int/2,
      channel_payload: &channel_payload/1,
      message_payload: &message_payload/2,
      server_payload: &server_payload/1,
      event_refs_payload: &event_refs_payload/2,
      sender_payload: &sender_payload/1,
      format_created_at: &format_created_at/1,
      maybe_iso8601: &maybe_iso8601/1,
      normalize_optional_string: &normalize_optional_string/1,
      validate_snapshot_payload: &validate_snapshot_payload/2,
      validate_snapshot_governance_payload: &validate_snapshot_governance_payload/3,
      apply_event: &EventRouter.apply_event/3,
      signed_headers: &RequestAuth.signed_headers/5,
      infer_remote_server_id_from_federation_id: &infer_remote_server_id_from_federation_id/1,
      outgoing_peer: &Peers.outgoing_peer/1,
      incoming_peer: &Peers.incoming_peer/1,
      infer_remote_server_id: &infer_remote_server_id/1,
      receive_event: &__MODULE__.receive_event/2,
      server_stream_id: &server_stream_id/1,
      channel_stream_id: &channel_stream_id/1
    })
  end

  defp inbound_context do
    Contexts.inbound(%{
      normalize_optional_string: &normalize_optional_string/1,
      parse_int: &parse_int/2,
      receive_event: &__MODULE__.receive_event/2,
      recover_sequence_gap: &__MODULE__.recover_sequence_gap/2,
      error_code: &Errors.error_code/1,
      validate_origin_bound_actors_in_event_data:
        &validate_origin_bound_actors_in_event_data/3,
      validate_origin_owned_identifiers_in_event_data:
        &validate_origin_owned_identifiers_in_event_data/3,
      apply_event: &EventRouter.apply_event/3
    })
  end

  defp ingress_context do
    %{
      validate_event_payload: &validate_event_payload/2,
      normalize_incoming_event_payload: &EventRouter.normalize_incoming_event_payload/1,
      claim_event_id: &EventTracking.claim_event_id/2,
      check_sequence: &EventTracking.check_sequence/2,
      apply_event: &EventRouter.apply_event/3,
      store_stream_position: &EventTracking.store_stream_position/3,
      normalize_incoming_batch_payload: &normalize_incoming_batch_payload/1,
      normalize_incoming_ephemeral_payload: &normalize_incoming_ephemeral_payload/1,
      normalize_session_stream_batch_payload: &normalize_session_stream_batch_payload/2,
      normalize_session_ephemeral_batch_payload: &normalize_session_ephemeral_batch_payload/2,
      process_incoming_event_result: &process_incoming_event_result/2,
      process_incoming_ephemeral_result: &process_incoming_ephemeral_result/2,
      batch_summary: &Inbound.batch_summary/2
    }
  end

  defp normalize_incoming_batch_payload(payload) do
    Inbound.normalize_incoming_batch_payload(payload, inbound_context())
  end

  defp normalize_incoming_ephemeral_payload(payload) do
    Inbound.normalize_incoming_ephemeral_payload(payload, inbound_context())
  end

  defp normalize_session_stream_batch_payload(payload, expected_delivery_id) do
    Inbound.normalize_session_stream_batch_payload(
      payload,
      expected_delivery_id,
      inbound_context()
    )
  end

  defp normalize_session_ephemeral_batch_payload(payload, expected_delivery_id) do
    Inbound.normalize_session_ephemeral_batch_payload(
      payload,
      expected_delivery_id,
      inbound_context()
    )
  end

  defp process_incoming_event_result(event, remote_domain) do
    Inbound.process_incoming_event_result(event, remote_domain, inbound_context())
  end

  defp process_incoming_ephemeral_result(item, remote_domain) do
    Inbound.process_incoming_ephemeral_result(item, remote_domain, inbound_context())
  end

  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp maybe_iso8601(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp maybe_iso8601(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
