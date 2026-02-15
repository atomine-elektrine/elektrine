defmodule Elektrine.Messaging.FederationOutboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_outbox_events" do
    field :event_id, :string
    field :event_type, :string
    field :stream_id, :string
    field :sequence, :integer
    field :payload, :map
    field :target_domains, {:array, :string}, default: []
    field :delivered_domains, {:array, :string}, default: []
    field :attempt_count, :integer, default: 0
    field :max_attempts, :integer, default: 8
    field :status, :string, default: "pending"
    field :next_retry_at, :utc_datetime
    field :last_error, :string
    field :partition_month, :date
    field :dispatched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(outbox_event, attrs) do
    outbox_event
    |> cast(attrs, [
      :event_id,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :target_domains,
      :delivered_domains,
      :attempt_count,
      :max_attempts,
      :status,
      :next_retry_at,
      :last_error,
      :partition_month,
      :dispatched_at
    ])
    |> validate_required([
      :event_id,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :target_domains,
      :status,
      :next_retry_at,
      :partition_month
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_inclusion(:status, ["pending", "delivered", "failed"])
    |> unique_constraint(:event_id, name: :messaging_federation_outbox_event_id_unique)
  end
end
