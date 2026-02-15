defmodule Elektrine.Repo.Migrations.RemoveBlueskyFromUsers do
  use Ecto.Migration

  def change do
    drop index(:users, [:bluesky_did])
    drop index(:users, [:bluesky_handle])

    alter table(:users) do
      remove :bluesky_did, :string
      remove :bluesky_handle, :string
      remove :bluesky_access_token, :text
      remove :bluesky_refresh_token, :text
      remove :bluesky_token_expires_at, :utc_datetime
      remove :bluesky_dpop_key, :text
      remove :bluesky_connected_at, :utc_datetime
    end
  end
end
