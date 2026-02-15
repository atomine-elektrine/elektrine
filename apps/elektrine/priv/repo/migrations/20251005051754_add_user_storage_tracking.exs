defmodule Elektrine.Repo.Migrations.AddUserStorageTracking do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :storage_used_bytes, :bigint, default: 0, null: false
      # 500MB default
      add :storage_limit_bytes, :bigint, default: 524_288_000, null: false
      add :storage_last_calculated_at, :utc_datetime
    end

    create index(:users, [:storage_used_bytes])
  end
end
