defmodule Elektrine.Repo.Migrations.MakeMailboxUserIdNullable do
  use Ecto.Migration

  def change do
    # We need to drop the existing foreign key constraint first
    execute "ALTER TABLE mailboxes DROP CONSTRAINT IF EXISTS mailboxes_user_id_fkey"

    # Remove the NOT NULL constraint from the user_id column
    alter table(:mailboxes) do
      modify :user_id, references(:users, on_delete: :nilify_all), null: true
    end

    # Remove the unique index on user_id (since we now want to allow nulls)
    drop_if_exists index(:mailboxes, [:user_id], unique: true)
    create_if_not_exists index(:mailboxes, [:user_id])

    # Add a new column to identify if this is a temporary mailbox
    alter table(:mailboxes) do
      add_if_not_exists :temporary, :boolean, default: false
    end
  end
end
