defmodule Elektrine.Repo.Migrations.CreateApiTokenRevocations do
  use Ecto.Migration

  def change do
    create table(:api_token_revocations) do
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:api_token_revocations, [:token_hash])
    create index(:api_token_revocations, [:expires_at])
  end
end
