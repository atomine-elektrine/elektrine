defmodule Elektrine.Repo.Migrations.AddUsernameEffectsToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      # Username text effects
      add :username_effect, :string, default: "none"
      add :username_glow_color, :string, default: "#8b5cf6"
      add :username_glow_intensity, :integer, default: 10
      add :username_shadow_color, :string, default: "#000000"
      add :username_gradient_from, :string
      add :username_gradient_to, :string
      add :username_animation_speed, :string, default: "normal"
    end
  end
end
