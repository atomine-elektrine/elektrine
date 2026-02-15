defmodule Elektrine.Repo.Migrations.AddNotificationPreferences do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notify_on_reply, :boolean, default: true
      add :notify_on_like, :boolean, default: true
      add :notify_on_email_received, :boolean, default: true
    end
  end
end
