defmodule Elektrine.Repo.Migrations.RemoveAnimatedTitleFromUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      remove :animated_title
    end
  end
end
