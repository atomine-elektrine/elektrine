defmodule Elektrine.Repo.Migrations.CreateUptimeChecks do
  use Ecto.Migration

  def change do
    create table(:uptime_checks) do
      add :monitor_id, references(:uptime_monitors, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :response_time_ms, :integer
      add :status_code, :integer
      add :error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:uptime_checks, [:monitor_id, :inserted_at])
  end
end
