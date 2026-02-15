defmodule Elektrine.Repo.Migrations.AddLinkDisplayStyleAndSections do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :link_display_style, :string, default: "circular"
    end

    alter table(:profile_links) do
      add :section, :string
    end
  end
end
