defmodule Elektrine.Repo.Migrations.AddVisibilityTogglesToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :hide_followers, :boolean, default: false
      add :hide_avatar, :boolean, default: false
      add :hide_timeline, :boolean, default: false
    end
  end
end
