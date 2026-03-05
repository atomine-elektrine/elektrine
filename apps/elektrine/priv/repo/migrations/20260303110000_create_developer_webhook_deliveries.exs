defmodule Elektrine.Repo.Migrations.CreateDeveloperWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:developer_webhook_deliveries) do
      add :webhook_id, references(:developer_webhooks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :event_id, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :response_status, :integer
      add :error, :text
      add :duration_ms, :integer
      add :last_attempted_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps()
    end

    create index(:developer_webhook_deliveries, [:user_id])
    create index(:developer_webhook_deliveries, [:webhook_id])
    create index(:developer_webhook_deliveries, [:status])
    create index(:developer_webhook_deliveries, [:inserted_at])
    create unique_index(:developer_webhook_deliveries, [:event_id])
  end
end
