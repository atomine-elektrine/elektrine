defmodule Elektrine.Repo.Migrations.RemoveTemporaryMailboxSystem do
  use Ecto.Migration

  def up do
    # First, clean up any messages marked as temporary
    execute """
    DELETE FROM email_messages 
    WHERE mailbox_type = 'temporary' 
       OR metadata->>'temporary' = 'true';
    """

    # Drop the temporary_mailboxes table
    drop_if_exists table(:temporary_mailboxes)

    # Remove temporary column from mailboxes table if it exists
    alter table(:mailboxes) do
      remove_if_exists :temporary, :boolean
    end

    # Remove mailbox_type column from messages table if it exists
    alter table(:email_messages) do
      remove_if_exists :mailbox_type, :string
    end
  end

  def down do
    # Recreate temporary_mailboxes table
    create table(:temporary_mailboxes) do
      add :email, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:temporary_mailboxes, [:email])
    create unique_index(:temporary_mailboxes, [:token])
    create index(:temporary_mailboxes, [:user_id])
    create index(:temporary_mailboxes, [:expires_at])

    # Add back temporary column to mailboxes
    alter table(:mailboxes) do
      add_if_not_exists :temporary, :boolean, default: false
    end

    # Add back mailbox_type to messages
    alter table(:email_messages) do
      add_if_not_exists :mailbox_type, :string
    end
  end
end
