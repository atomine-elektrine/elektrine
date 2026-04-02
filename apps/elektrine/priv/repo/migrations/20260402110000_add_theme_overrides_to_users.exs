defmodule Elektrine.Repo.Migrations.AddThemeOverridesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme_overrides, :map, null: false, default: %{}
    end
  end
end
