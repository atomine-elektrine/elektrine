defmodule Elektrine.Repo.Migrations.AddSpamFilterEnabledToMailboxes do
  use Ecto.Migration

  def change do
    alter table(:email_mailboxes) do
      add :spam_filter_enabled, :boolean, null: false, default: true
    end
  end
end
