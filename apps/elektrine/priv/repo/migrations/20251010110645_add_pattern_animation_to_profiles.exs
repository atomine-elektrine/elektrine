defmodule Elektrine.Repo.Migrations.AddPatternAnimationToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :pattern_animated, :boolean, default: false
      add :pattern_animation_speed, :string, default: "normal"
    end
  end
end
