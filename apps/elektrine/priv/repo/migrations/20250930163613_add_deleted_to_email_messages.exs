defmodule Elektrine.Repo.Migrations.AddDeletedToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :deleted, :boolean, default: false, null: false
    end

    create index(:email_messages, [:deleted])
    create index(:email_messages, [:mailbox_id, :deleted])
  end
end
