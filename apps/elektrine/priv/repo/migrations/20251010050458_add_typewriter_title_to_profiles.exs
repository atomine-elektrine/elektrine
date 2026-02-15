defmodule Elektrine.Repo.Migrations.AddTypewriterTitleToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :typewriter_title, :boolean, default: false
    end
  end
end
