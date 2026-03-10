defmodule Elektrine.Messaging.FederationEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_events" do
    field(:protocol_version, :string)
    field(:event_id, :string)
    field(:idempotency_key, :string)
    field(:origin_domain, :string)
    field(:event_type, :string)
    field(:stream_id, :string)
    field(:sequence, :integer)
    field(:payload, :map)
    field(:received_at, :utc_datetime)

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :protocol_version,
      :event_id,
      :idempotency_key,
      :origin_domain,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :received_at
    ])
    |> validate_required([
      :protocol_version,
      :event_id,
      :idempotency_key,
      :origin_domain,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :received_at
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> unique_constraint(:event_id,
      name: :messaging_federation_events_origin_event_id_unique
    )
    |> unique_constraint(:idempotency_key,
      name: :messaging_federation_events_origin_idempotency_unique
    )
  end
end
