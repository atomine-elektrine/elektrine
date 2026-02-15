defmodule Elektrine.Repo.Migrations.AddAliasUsernameConflictIndexes do
  use Ecto.Migration

  def change do
    # Add index for enabled aliases to speed up conflict checking
    create index(:email_aliases, [:alias_email, :enabled])

    # The usernames table already has a unique index on username
    # which is sufficient for our conflict checking
  end
end
