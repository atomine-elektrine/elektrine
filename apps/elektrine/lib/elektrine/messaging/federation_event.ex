defmodule Elektrine.Messaging.FederationEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_events" do
    field :event_id, :string
    field :origin_domain, :string
    field :event_type, :string
    field :stream_id, :string
    field :sequence, :integer
    field :payload, :map
    field :received_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :origin_domain,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :received_at
    ])
    |> validate_required([
      :event_id,
      :origin_domain,
      :event_type,
      :stream_id,
      :sequence,
      :payload,
      :received_at
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> unique_constraint(:event_id)
  end
end
