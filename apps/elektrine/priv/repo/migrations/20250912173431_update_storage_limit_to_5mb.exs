defmodule Elektrine.Repo.Migrations.UpdateStorageLimitTo5mb do
  use Ecto.Migration

  def change do
    # Update all existing mailboxes to have 5MB storage limit
    execute "UPDATE mailboxes SET storage_limit_bytes = 5242880 WHERE storage_limit_bytes = 2097152"
  end
end
