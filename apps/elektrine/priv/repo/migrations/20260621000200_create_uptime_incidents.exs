defmodule Elektrine.Repo.Migrations.CreateUptimeIncidents do
  use Ecto.Migration

  def change do
    create table(:uptime_incidents) do
      add :monitor_id, references(:uptime_monitors, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_incidents, [:monitor_id])

    create unique_index(:uptime_incidents, [:monitor_id],
             where: "resolved_at IS NULL",
             name: :uptime_incidents_open_unique
           )
  end
end
