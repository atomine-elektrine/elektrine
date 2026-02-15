defmodule Elektrine.Repo.Migrations.AddCircularLinksPositionToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :circular_links_position, :string, default: "top", null: false
    end
  end
end
