defmodule Elektrine.Uptime.Incident do
  @moduledoc """
  Downtime incident for a monitor. An incident is open while `resolved_at` is nil;
  at most one open incident may exist per monitor (enforced by a partial unique index).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_incidents" do
    field :started_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :last_error, :string

    belongs_to :monitor, Elektrine.Uptime.Monitor

    timestamps(type: :utc_datetime)
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:started_at, :resolved_at, :last_error, :monitor_id])
    |> validate_required([:started_at, :monitor_id])
    |> foreign_key_constraint(:monitor_id)
    |> unique_constraint(:monitor_id, name: :uptime_incidents_open_unique)
  end
end
