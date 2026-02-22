defmodule Elektrine.Repo.Migrations.AddBlueskyInboundTracking do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bluesky_inbound_cursor, :text
      add :bluesky_inbound_last_polled_at, :utc_datetime
    end

    create table(:bluesky_inbound_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event_id, :string, null: false
      add :reason, :string
      add :related_post_uri, :text
      add :processed_at, :utc_datetime, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bluesky_inbound_events, [:user_id, :event_id])
    create index(:bluesky_inbound_events, [:user_id, :processed_at])
    create index(:bluesky_inbound_events, [:related_post_uri])
  end
end
