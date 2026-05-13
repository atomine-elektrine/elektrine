defmodule Elektrine.Email.InternalDeliveryAttempt do
  @moduledoc """
  Immutable attempt history for local mailbox delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "internal_email_delivery_attempts" do
    field :attempt, :integer
    field :status, :string
    field :error, :string
    field :metadata, :map, default: %{}
    field :attempted_at, :utc_datetime

    belongs_to :delivery, Elektrine.Email.InternalDelivery
    belongs_to :delivered_message, Elektrine.Email.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :delivery_id,
      :attempt,
      :status,
      :delivered_message_id,
      :error,
      :metadata,
      :attempted_at
    ])
    |> validate_required([:delivery_id, :attempt, :status, :attempted_at])
  end
end
