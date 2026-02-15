defmodule Elektrine.Repo.Migrations.DropRelaysTable do
  use Ecto.Migration

  def up do
    drop table(:activitypub_relays)
  end

  def down do
    create table(:activitypub_relays) do
      add :url, :string, null: false
      add :inbox_url, :string, null: false
      add :domain, :string, null: false
      add :state, :string, default: "pending"
      add :enabled, :boolean, default: true
      add :follow_activity_id, :string
      add :last_successful_at, :utc_datetime
      add :last_error, :text

      timestamps()
    end

    create unique_index(:activitypub_relays, [:url])
  end
end
