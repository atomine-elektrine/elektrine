defmodule Elektrine.Repo.Migrations.AddUserToTemporaryMailboxes do
  use Ecto.Migration

  def change do
    alter table(:temporary_mailboxes) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:temporary_mailboxes, [:user_id])
  end
end
