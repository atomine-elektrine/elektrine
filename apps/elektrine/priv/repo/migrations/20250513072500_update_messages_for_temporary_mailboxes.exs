defmodule Elektrine.Repo.Migrations.UpdateMessagesForTemporaryMailboxes do
  use Ecto.Migration

  def change do
    # First drop the existing foreign key constraint
    execute "ALTER TABLE email_messages DROP CONSTRAINT IF EXISTS email_messages_mailbox_id_fkey"

    # Add a new polymorphic column to identify the mailbox type
    alter table(:email_messages) do
      add :mailbox_type, :string, default: "regular"
    end

    # Create index for faster searching
    create index(:email_messages, [:mailbox_type, :mailbox_id])
  end
end
