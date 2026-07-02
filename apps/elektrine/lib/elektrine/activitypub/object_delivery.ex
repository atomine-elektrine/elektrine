defmodule Elektrine.ActivityPub.ObjectDelivery do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_object_deliveries" do
    field :object_id, :string
    field :inbox_url, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :last_delivered_at, :utc_datetime

    belongs_to :activity, Elektrine.ActivityPub.Activity

    timestamps()
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :object_id,
      :inbox_url,
      :activity_id,
      :first_seen_at,
      :last_seen_at,
      :last_delivered_at
    ])
    |> validate_required([:object_id, :inbox_url, :first_seen_at, :last_seen_at])
    |> unique_constraint([:object_id, :inbox_url],
      name: :activitypub_object_deliveries_object_inbox_unique
    )
  end
end
