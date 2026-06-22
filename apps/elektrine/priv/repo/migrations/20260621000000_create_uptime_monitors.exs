defmodule Elektrine.Repo.Migrations.CreateUptimeMonitors do
  use Ecto.Migration

  def change do
    create table(:uptime_monitors) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :check_type, :string, null: false
      add :target, :string, null: false
      add :port, :integer
      add :expected_status, :integer, default: 200
      add :keyword, :string
      add :interval_seconds, :integer, default: 300, null: false
      add :timeout_ms, :integer, default: 10_000, null: false
      add :enabled, :boolean, default: true, null: false
      add :last_status, :string
      add :last_checked_at, :utc_datetime
      add :consecutive_failures, :integer, default: 0, null: false
      add :failure_threshold, :integer, default: 2, null: false
      add :notify_email, :boolean, default: false, null: false
      add :notify_in_app, :boolean, default: true, null: false
      add :public_slug, :string
      add :visibility, :string, default: "private", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_monitors, [:user_id])
    create index(:uptime_monitors, [:enabled, :last_checked_at])

    create unique_index(:uptime_monitors, [:public_slug],
             where: "public_slug IS NOT NULL",
             name: :uptime_monitors_public_slug_unique
           )
  end
end
