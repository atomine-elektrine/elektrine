defmodule Elektrine.Repo.Migrations.AddBlueskyBridgeFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bluesky_enabled, :boolean, default: false, null: false
      add :bluesky_identifier, :string
      add :bluesky_app_password, :text
      add :bluesky_did, :string
      add :bluesky_pds_url, :string
    end

    create index(:users, [:bluesky_enabled])
    create index(:users, [:bluesky_identifier])
    create index(:users, [:bluesky_did])

    alter table(:messages) do
      add :bluesky_uri, :text
      add :bluesky_cid, :string
    end

    create unique_index(:messages, [:bluesky_uri], where: "bluesky_uri IS NOT NULL")
    create index(:messages, [:bluesky_cid])
  end
end
