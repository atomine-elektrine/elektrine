defmodule Elektrine.Repo.Migrations.AddBlueskyIdentityToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bluesky_did, :string
      add :bluesky_handle, :string
      add :bluesky_access_token, :text
      add :bluesky_refresh_token, :text
      add :bluesky_token_expires_at, :utc_datetime
      add :bluesky_dpop_key, :text
      add :bluesky_connected_at, :utc_datetime
    end

    create index(:users, [:bluesky_did])
    create index(:users, [:bluesky_handle])
  end
end
