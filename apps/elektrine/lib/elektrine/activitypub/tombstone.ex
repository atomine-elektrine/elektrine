defmodule Elektrine.ActivityPub.Tombstone do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "activitypub_tombstones" do
    field :activity_id, :string
    field :actor_uri, :string
    field :object_id, :string
    field :data, :map, default: %{}
    field :received_at, :utc_datetime

    timestamps()
  end

  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [:activity_id, :actor_uri, :object_id, :data, :received_at])
    |> validate_required([:actor_uri, :object_id, :received_at])
    |> unique_constraint([:actor_uri, :object_id],
      name: :activitypub_tombstones_actor_object_unique
    )
  end
end
