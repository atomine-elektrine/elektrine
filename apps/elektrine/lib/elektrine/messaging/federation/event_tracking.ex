defmodule Elektrine.Messaging.Federation.EventTracking do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Messaging.{ArblargSDK, FederationEvent, FederationStreamPosition}
  alias Elektrine.Repo

  def claim_event_id(payload, remote_domain) when is_map(payload) and is_binary(remote_domain) do
    inserted_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    received_now = DateTime.utc_now() |> DateTime.truncate(:second)

    protocol_version = payload["protocol_version"] || ArblargSDK.protocol_version()
    idempotency_key = payload["idempotency_key"] || payload["event_id"]

    attrs = [
      %{
        protocol_version: protocol_version,
        event_id: payload["event_id"],
        idempotency_key: idempotency_key,
        origin_domain: remote_domain,
        event_type: ArblargSDK.canonical_event_type(payload["event_type"]),
        stream_id: payload["stream_id"],
        sequence: parse_int(payload["sequence"], 0),
        payload: payload,
        received_at: received_now,
        inserted_at: inserted_now
      }
    ]

    {count, _} = Repo.insert_all(FederationEvent, attrs, on_conflict: :nothing)

    if count == 1 do
      :new
    else
      :duplicate
    end
  end

  def check_sequence(payload, remote_domain) when is_map(payload) and is_binary(remote_domain) do
    stream_id = payload["stream_id"]
    incoming_sequence = parse_int(payload["sequence"], 0)

    position =
      from(p in FederationStreamPosition,
        where: p.origin_domain == ^remote_domain and p.stream_id == ^stream_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    last_sequence =
      if position do
        position.last_sequence
      else
        0
      end

    cond do
      incoming_sequence <= last_sequence -> :stale
      incoming_sequence > last_sequence + 1 -> {:error, :sequence_gap}
      true -> :ok
    end
  end

  def store_stream_position(remote_domain, stream_id, sequence)
      when is_binary(remote_domain) and is_binary(stream_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = [
      %{
        origin_domain: remote_domain,
        stream_id: stream_id,
        last_sequence: parse_int(sequence, 0),
        inserted_at: now,
        updated_at: now
      }
    ]

    {_count, _} =
      Repo.insert_all(FederationStreamPosition, attrs,
        on_conflict: [set: [last_sequence: parse_int(sequence, 0), updated_at: now]],
        conflict_target: [:origin_domain, :stream_id]
      )

    :ok
  end

  def store_stream_position(_remote_domain, _stream_id, _sequence), do: :ok
end
