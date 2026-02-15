defmodule Elektrine.Repo.Migrations.AddDiscussionAndCommentNotificationPreferences do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notify_on_discussion_reply, :boolean, default: true
      add :notify_on_comment, :boolean, default: true
    end
  end
end
