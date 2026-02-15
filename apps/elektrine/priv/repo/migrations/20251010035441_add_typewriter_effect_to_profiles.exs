defmodule Elektrine.Repo.Migrations.AddTypewriterEffectToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :typewriter_effect, :boolean, default: false
      add :typewriter_speed, :string, default: "normal"
    end
  end
end
