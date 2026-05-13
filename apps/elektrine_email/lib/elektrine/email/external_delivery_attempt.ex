defmodule Elektrine.Email.ExternalDeliveryAttempt do
  @moduledoc """
  Immutable attempt history for external recipient delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "external_email_delivery_attempts" do
    field :attempt, :integer
    field :status, :string
    field :provider, :string
    field :provider_message_id, :string
    field :response_code, :string
    field :error, :string
    field :metadata, :map, default: %{}
    field :attempted_at, :utc_datetime

    belongs_to :delivery, Elektrine.Email.ExternalDelivery

    timestamps(type: :utc_datetime)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :delivery_id,
      :attempt,
      :status,
      :provider,
      :provider_message_id,
      :response_code,
      :error,
      :metadata,
      :attempted_at
    ])
    |> validate_required([:delivery_id, :attempt, :status, :attempted_at])
  end
end
