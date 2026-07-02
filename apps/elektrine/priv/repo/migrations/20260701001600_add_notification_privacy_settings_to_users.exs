defmodule Elektrine.Repo.Migrations.AddNotificationPrivacySettingsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :block_notifications_from_strangers, :boolean, default: false, null: false
      add :hide_notification_contents, :boolean, default: false, null: false
    end
  end
end
