defmodule Elektrine.Repo.Migrations.CreateDeveloperWebhooks do
  use Ecto.Migration

  def change do
    create table(:developer_webhooks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :url, :string, null: false
      add :events, {:array, :string}, default: [], null: false
      add :secret, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :last_triggered_at, :utc_datetime
      add :last_response_status, :integer
      add :last_error, :text

      timestamps()
    end

    create index(:developer_webhooks, [:user_id])
    create index(:developer_webhooks, [:user_id, :enabled])
  end
end
