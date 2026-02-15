defmodule Elektrine.Repo.Migrations.UpdateStorageLimitTo500mb do
  use Ecto.Migration

  def change do
    # Update existing mailboxes to 500MB limit (500 * 1024 * 1024 = 524288000 bytes)
    execute "UPDATE mailboxes SET storage_limit_bytes = 524288000 WHERE storage_limit_bytes = 5242880"
  end
end
