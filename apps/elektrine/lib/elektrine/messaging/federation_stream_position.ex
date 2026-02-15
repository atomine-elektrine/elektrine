defmodule Elektrine.Messaging.FederationStreamPosition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_stream_positions" do
    field :origin_domain, :string
    field :stream_id, :string
    field :last_sequence, :integer, default: 0

    timestamps()
  end

  @doc false
  def changeset(position, attrs) do
    position
    |> cast(attrs, [:origin_domain, :stream_id, :last_sequence])
    |> validate_required([:origin_domain, :stream_id, :last_sequence])
    |> validate_number(:last_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint(:stream_id, name: :messaging_federation_stream_positions_unique)
  end
end
