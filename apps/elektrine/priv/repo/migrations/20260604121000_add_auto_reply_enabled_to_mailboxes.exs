defmodule Elektrine.Repo.Migrations.AddAutoReplyEnabledToMailboxes do
  use Ecto.Migration

  def change do
    alter table(:email_mailboxes) do
      add :auto_reply_enabled, :boolean, null: false, default: true
    end
  end
end
