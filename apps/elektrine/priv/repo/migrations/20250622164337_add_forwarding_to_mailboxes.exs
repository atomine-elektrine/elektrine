defmodule Elektrine.Repo.Migrations.AddForwardingToMailboxes do
  use Ecto.Migration

  def change do
    alter table(:mailboxes) do
      add :forward_to, :string
      add :forward_enabled, :boolean, default: false, null: false
    end

    create index(:mailboxes, [:forward_enabled])
  end
end
