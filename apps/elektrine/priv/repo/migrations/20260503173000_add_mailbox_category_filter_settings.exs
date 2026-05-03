defmodule Elektrine.Repo.Migrations.AddMailboxCategoryFilterSettings do
  use Ecto.Migration

  def change do
    alter table(:email_mailboxes) do
      add :digest_filter_enabled, :boolean, null: false, default: true
      add :ledger_filter_enabled, :boolean, null: false, default: true
    end
  end
end
