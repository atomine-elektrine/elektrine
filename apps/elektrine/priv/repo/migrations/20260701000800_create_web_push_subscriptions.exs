defmodule Elektrine.Repo.Migrations.CreateWebPushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:web_push_subscriptions) do
      add :endpoint, :text, null: false
      add :endpoint_hash, :string, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :alerts, :map, null: false, default: %{}
      add :policy, :string, null: false, default: "all"
      add :enabled, :boolean, null: false, default: true
      add :last_used_at, :utc_datetime
      add :failed_count, :integer, null: false, default: 0
      add :last_error, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:web_push_subscriptions, [:endpoint_hash])
    create index(:web_push_subscriptions, [:user_id, :enabled])
    create index(:web_push_subscriptions, [:last_used_at])
  end
end
