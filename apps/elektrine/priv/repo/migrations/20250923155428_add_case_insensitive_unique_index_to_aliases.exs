defmodule Elektrine.Repo.Migrations.AddCaseInsensitiveUniqueIndexToAliases do
  use Ecto.Migration

  def change do
    # This migration is now handled by FixDuplicateAliasesBeforeIndex
    # which first removes duplicates before creating the index
    # Leaving this as a no-op to preserve migration history
  end
end
