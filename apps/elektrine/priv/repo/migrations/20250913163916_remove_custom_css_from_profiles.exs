defmodule Elektrine.Repo.Migrations.RemoveCustomCssFromProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      remove :custom_css
    end

    alter table(:profile_links) do
      remove :custom_style
    end
  end
end
