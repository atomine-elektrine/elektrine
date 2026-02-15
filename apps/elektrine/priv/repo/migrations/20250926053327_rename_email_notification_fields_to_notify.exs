defmodule Elektrine.Repo.Migrations.RenameEmailNotificationFieldsToNotify do
  use Ecto.Migration

  def change do
    # Rename the columns from email_on_* to notify_on_*
    rename table(:users), :email_on_new_follower, to: :notify_on_new_follower
    rename table(:users), :email_on_direct_message, to: :notify_on_direct_message
    rename table(:users), :email_on_mention, to: :notify_on_mention
    rename table(:users), :email_on_group_invite, to: :notify_on_group_invite
  end
end
