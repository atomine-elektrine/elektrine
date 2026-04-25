defmodule Elektrine.Repo.Migrations.AddBurnAfterReadToDriveShares do
  use Ecto.Migration

  def change do
    alter table(:drive_shares) do
      add :burn_after_read, :boolean, null: false, default: false
    end
  end
end
