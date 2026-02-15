defmodule Elektrine.Repo.Migrations.AddLinkHighlightEffectToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :link_highlight_effect, :string, default: "none", null: false
    end
  end
end
