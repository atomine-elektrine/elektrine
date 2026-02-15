defmodule Elektrine.Repo.Migrations.FixDuplicateAliasesBeforeIndex do
  use Ecto.Migration

  def up do
    # Find and remove duplicate aliases (keep the one with the lowest ID)
    execute """
    DELETE FROM email_aliases a1
    WHERE EXISTS (
      SELECT 1
      FROM email_aliases a2
      WHERE lower(a1.alias_email) = lower(a2.alias_email)
      AND a1.id > a2.id
    )
    """

    # Check if the index already exists before creating it
    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS email_aliases_alias_email_ci_unique
    ON email_aliases (lower(alias_email))
    """

    # Also add a regular index for performance (if it doesn't exist)
    execute """
    CREATE INDEX IF NOT EXISTS email_aliases_alias_email_lower_idx
    ON email_aliases (lower(alias_email))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS email_aliases_alias_email_lower_idx"
    execute "DROP INDEX IF EXISTS email_aliases_alias_email_ci_unique"
  end
end
