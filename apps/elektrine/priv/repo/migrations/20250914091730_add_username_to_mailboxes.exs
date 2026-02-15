defmodule Elektrine.Repo.Migrations.AddUsernameToMailboxes do
  use Ecto.Migration

  def up do
    # Add username field
    alter table(:mailboxes) do
      add :username, :string
    end

    # Populate username from email field for existing mailboxes
    execute """
    UPDATE mailboxes
    SET username = split_part(email, '@', 1)
    WHERE username IS NULL AND email IS NOT NULL
    """

    # Create index on username for lookups
    create index(:mailboxes, [:username])
  end

  def down do
    alter table(:mailboxes) do
      remove :username
    end
  end
end
