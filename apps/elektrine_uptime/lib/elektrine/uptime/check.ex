defmodule Elektrine.Uptime.Check do
  @moduledoc """
  Append-only result of a single probe against a monitor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(up down)

  schema "uptime_checks" do
    field :status, :string
    field :response_time_ms, :integer
    field :status_code, :integer
    field :error, :string

    belongs_to :monitor, Elektrine.Uptime.Monitor

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [:status, :response_time_ms, :status_code, :error, :monitor_id])
    |> validate_required([:status, :monitor_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:response_time_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:monitor_id)
  end
end
