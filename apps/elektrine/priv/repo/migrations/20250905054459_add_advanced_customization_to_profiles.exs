defmodule Elektrine.Repo.Migrations.AddAdvancedCustomizationToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :text_color, :string, default: "#ffffff"
      add :background_color, :string, default: "#000000"
      add :icon_color, :string, default: "#ffffff"
      add :profile_opacity, :float, default: 1.0
      add :profile_blur, :integer, default: 0
      add :monochrome_icons, :boolean, default: false
      add :animated_title, :boolean, default: false
      add :volume_control, :boolean, default: false
      add :use_discord_avatar, :boolean, default: false
    end
  end
end
