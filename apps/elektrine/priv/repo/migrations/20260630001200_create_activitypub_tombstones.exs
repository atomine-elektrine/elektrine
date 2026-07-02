defmodule Elektrine.Repo.Migrations.CreateActivitypubTombstones do
  use Ecto.Migration

  def change do
    create table(:activitypub_tombstones) do
      add :activity_id, :text
      add :actor_uri, :text, null: false
      add :object_id, :text, null: false
      add :data, :map, null: false, default: %{}
      add :received_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:activitypub_tombstones, [:actor_uri, :object_id],
             name: :activitypub_tombstones_actor_object_unique
           )

    create index(:activitypub_tombstones, [:object_id])
    create index(:activitypub_tombstones, [:actor_uri])
  end
end
