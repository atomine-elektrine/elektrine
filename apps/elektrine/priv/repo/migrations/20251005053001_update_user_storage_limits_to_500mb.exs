defmodule Elektrine.Repo.Migrations.UpdateUserStorageLimitsTo500mb do
  use Ecto.Migration

  def up do
    # Update all existing users with old 25MB limit to new 500MB limit
    execute "UPDATE users SET storage_limit_bytes = 524288000 WHERE storage_limit_bytes < 524288000"
  end

  def down do
    # Revert to 25MB limit
    execute "UPDATE users SET storage_limit_bytes = 26214400 WHERE storage_limit_bytes = 524288000"
  end
end
