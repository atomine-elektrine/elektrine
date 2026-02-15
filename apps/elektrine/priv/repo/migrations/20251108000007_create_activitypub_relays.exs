defmodule Elektrine.Repo.Migrations.CreateActivitypubRelays do
  use Ecto.Migration

  def change do
    create table(:activitypub_relays) do
      # Relay actor URL
      add :url, :string, null: false
      add :inbox_url, :string, null: false
      add :domain, :string, null: false
      # pending, accepted, rejected
      add :state, :string, default: "pending"
      # Track our Follow activity
      add :follow_activity_id, :string
      add :enabled, :boolean, default: true
      add :last_error, :text
      add :last_successful_at, :utc_datetime

      timestamps()
    end

    create unique_index(:activitypub_relays, [:url])
    create index(:activitypub_relays, [:domain])
    create index(:activitypub_relays, [:state])
    create index(:activitypub_relays, [:enabled])
  end
end
