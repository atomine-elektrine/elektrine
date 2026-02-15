defmodule Elektrine.Repo.Migrations.SetManuallyApproveFollowersDefaultTrue do
  use Ecto.Migration

  def up do
    # Update the default value for new records
    alter table(:users) do
      modify :activitypub_manually_approve_followers, :boolean, default: true
    end

    # Update existing users to manually approve followers by default
    execute "UPDATE users SET activitypub_manually_approve_followers = true WHERE activitypub_manually_approve_followers = false OR activitypub_manually_approve_followers IS NULL"
  end

  def down do
    # Revert the default value
    alter table(:users) do
      modify :activitypub_manually_approve_followers, :boolean, default: false
    end

    # Don't revert the data - keep user preferences
  end
end
