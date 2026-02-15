defmodule Elektrine.Repo.Migrations.CreateUserProfilesAndLinks do
  use Ecto.Migration

  def change do
    create table(:user_profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :display_name, :string
      add :description, :text
      add :custom_css, :text
      add :theme, :string, default: "purple"
      add :accent_color, :string, default: "#8b5cf6"
      add :font_family, :string, default: "Inter"
      add :cursor_style, :string, default: "default"
      add :avatar_url, :string
      add :banner_url, :string
      add :background_url, :string
      add :background_type, :string, default: "gradient"
      add :music_url, :string
      add :music_title, :string
      add :discord_user_id, :string
      add :show_discord_presence, :boolean, default: false
      add :is_public, :boolean, default: true
      add :page_views, :integer, default: 0

      timestamps()
    end

    create table(:profile_links) do
      add :profile_id, references(:user_profiles, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :url, :string, null: false
      add :description, :string
      add :icon, :string, default: "hero-link"
      # "twitter", "instagram", "github", etc.
      add :platform, :string
      add :position, :integer, default: 0
      add :clicks, :integer, default: 0
      add :is_active, :boolean, default: true
      # Custom CSS for this specific link
      add :custom_style, :text

      timestamps()
    end

    create unique_index(:user_profiles, [:user_id])
    create index(:profile_links, [:profile_id])
    create index(:profile_links, [:position])
    create index(:profile_links, [:is_active])
  end
end
