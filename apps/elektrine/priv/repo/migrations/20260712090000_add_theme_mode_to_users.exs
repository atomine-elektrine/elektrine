defmodule Elektrine.Repo.Migrations.AddThemeModeToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :theme_mode, :string, null: false, default: "system"
    end

    execute("UPDATE users SET theme_mode = 'custom' WHERE theme_overrides <> '{}'")
  end

  def down do
    alter table(:users) do
      remove :theme_mode
    end
  end
end
