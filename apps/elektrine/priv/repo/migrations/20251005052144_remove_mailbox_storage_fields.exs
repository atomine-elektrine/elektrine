defmodule Elektrine.Repo.Migrations.RemoveMailboxStorageFields do
  use Ecto.Migration

  def change do
    alter table(:mailboxes) do
      remove :storage_used_bytes
      remove :storage_limit_bytes
    end
  end
end
