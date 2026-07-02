defmodule Elektrine.Repo.Migrations.AddAccountListPrivacySettingsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :hide_followers, :boolean, default: false, null: false
      add :hide_follows, :boolean, default: false, null: false
      add :hide_favorites, :boolean, default: false, null: false
    end
  end
end
