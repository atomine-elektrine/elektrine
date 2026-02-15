defmodule Elektrine.Messaging.FederationStreamCounter do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_stream_counters" do
    field :stream_id, :string
    field :next_sequence, :integer, default: 1

    timestamps()
  end

  @doc false
  def changeset(counter, attrs) do
    counter
    |> cast(attrs, [:stream_id, :next_sequence])
    |> validate_required([:stream_id, :next_sequence])
    |> validate_number(:next_sequence, greater_than: 0)
    |> unique_constraint(:stream_id, name: :messaging_federation_stream_counters_unique)
  end
end
