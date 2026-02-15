defmodule Elektrine.Repo.Migrations.AddHideShareButtonToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :hide_share_button, :boolean, default: false
    end
  end
end
