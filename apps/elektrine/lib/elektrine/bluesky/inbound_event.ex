defmodule Elektrine.Bluesky.InboundEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "bluesky_inbound_events" do
    belongs_to :user, Elektrine.Accounts.User

    field :event_id, :string
    field :reason, :string
    field :related_post_uri, :string
    field :processed_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :event_id, :reason, :related_post_uri, :processed_at, :metadata])
    |> validate_required([:user_id, :event_id, :processed_at])
    |> validate_length(:event_id, max: 255)
    |> unique_constraint([:user_id, :event_id])
  end
end
