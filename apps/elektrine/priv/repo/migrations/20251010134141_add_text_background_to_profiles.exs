defmodule Elektrine.Repo.Migrations.AddTextBackgroundToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :text_background, :boolean, default: false
    end
  end
end
