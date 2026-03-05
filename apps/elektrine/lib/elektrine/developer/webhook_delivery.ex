defmodule Elektrine.Developer.WebhookDelivery do
  @moduledoc """
  Persistent record of outbound developer webhook delivery attempts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(pending delivered failed)

  schema "developer_webhook_deliveries" do
    field :event, :string
    field :event_id, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :response_status, :integer
    field :error, :string
    field :duration_ms, :integer
    field :last_attempted_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :webhook, Elektrine.Developer.Webhook
    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Changeset for creating a webhook delivery record.
  """
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:webhook_id, :user_id, :event, :event_id, :payload, :status])
    |> validate_required([:webhook_id, :user_id, :event, :event_id, :payload, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:event, min: 1, max: 120)
    |> foreign_key_constraint(:webhook_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for recording attempt metadata and result.
  """
  def result_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :status,
      :attempt_count,
      :response_status,
      :error,
      :duration_ms,
      :last_attempted_at,
      :delivered_at
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
