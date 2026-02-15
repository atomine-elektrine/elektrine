defmodule Elektrine.Repo.Migrations.AddStorageTrackingToMailboxes do
  use Ecto.Migration

  def change do
    alter table(:mailboxes) do
      add :storage_used_bytes, :bigint, default: 0, null: false
      # 5MB = 5 * 1024 * 1024 bytes
      add :storage_limit_bytes, :bigint, default: 5_242_880, null: false
    end

    # Add index for efficient querying of storage usage
    create index(:mailboxes, [:storage_used_bytes])
  end
end
