defmodule Elektrine.Repo.Migrations.CreateExternalEmailOpsTables do
  use Ecto.Migration

  def change do
    create table(:external_email_delivery_controls) do
      add :scope_type, :string, null: false
      add :scope_value, :string, null: false
      add :active, :boolean, null: false, default: true
      add :reason, :text
      add :paused_by_id, references(:users, on_delete: :nilify_all)
      add :paused_at, :utc_datetime
      add :resumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:external_email_delivery_controls, [:scope_type, :scope_value],
             name: :external_email_delivery_controls_scope_unique
           )

    create index(:external_email_delivery_controls, [:active])

    create table(:external_email_metric_snapshots) do
      add :metrics, :map, null: false, default: %{}
      add :queue_depth, :integer, null: false, default: 0
      add :stuck_count, :integer, null: false, default: 0
      add :bounce_rate, :float, null: false, default: 0.0
      add :complaint_rate, :float, null: false, default: 0.0
      add :captured_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:external_email_metric_snapshots, [:captured_at])
  end
end
