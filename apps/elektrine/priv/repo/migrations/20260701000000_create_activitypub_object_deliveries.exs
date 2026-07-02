defmodule Elektrine.Repo.Migrations.CreateActivitypubObjectDeliveries do
  use Ecto.Migration

  def change do
    create table(:activitypub_object_deliveries) do
      add :object_id, :text, null: false
      add :inbox_url, :text, null: false
      add :activity_id, references(:activitypub_activities, on_delete: :nilify_all)
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :last_delivered_at, :utc_datetime

      timestamps()
    end

    create unique_index(:activitypub_object_deliveries, [:object_id, :inbox_url],
             name: :activitypub_object_deliveries_object_inbox_unique
           )

    create index(:activitypub_object_deliveries, [:object_id])
    create index(:activitypub_object_deliveries, [:inbox_url])
  end
end
