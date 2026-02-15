defmodule Elektrine.ActivityPub.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_deliveries" do
    field :inbox_url, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_attempt_at, :utc_datetime
    field :next_retry_at, :utc_datetime
    field :error_message, :string

    belongs_to :activity, Elektrine.ActivityPub.Activity

    timestamps()
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :activity_id,
      :inbox_url,
      :status,
      :attempts,
      :last_attempt_at,
      :next_retry_at,
      :error_message
    ])
    |> validate_required([:inbox_url])
    |> validate_inclusion(:status, ["pending", "delivered", "failed"])
  end
end
