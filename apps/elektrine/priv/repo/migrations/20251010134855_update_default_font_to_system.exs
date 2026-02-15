defmodule Elektrine.Repo.Migrations.UpdateDefaultFontToSystem do
  use Ecto.Migration

  def up do
    # Update existing profiles with "Inter" to use system default (NULL)
    execute "UPDATE user_profiles SET font_family = NULL WHERE font_family = 'Inter'"
  end

  def down do
    # Revert back to Inter for profiles that had NULL
    execute "UPDATE user_profiles SET font_family = 'Inter' WHERE font_family IS NULL"
  end
end
