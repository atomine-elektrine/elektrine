defmodule Elektrine.Repo.Migrations.RemoveFontFamilyDefault do
  use Ecto.Migration

  def up do
    # Remove the default value from the font_family column
    execute "ALTER TABLE user_profiles ALTER COLUMN font_family DROP DEFAULT"
  end

  def down do
    # Restore the Inter default if rolled back
    execute "ALTER TABLE user_profiles ALTER COLUMN font_family SET DEFAULT 'Inter'"
  end
end
