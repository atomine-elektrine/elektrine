defmodule Elektrine.Repo.Migrations.AddCaseInsensitiveUniqueIndexToUsers do
  use Ecto.Migration

  def change do
    # Create a unique index on lowercase username to prevent case-sensitive duplicates
    create unique_index(:users, ["lower(username)"], name: :users_username_ci_unique)

    # Also create a unique index on lowercase mailbox email
    create unique_index(:mailboxes, ["lower(email)"], name: :mailboxes_email_ci_unique)
  end
end
