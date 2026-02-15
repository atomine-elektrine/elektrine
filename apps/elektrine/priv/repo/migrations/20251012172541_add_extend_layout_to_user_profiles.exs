defmodule Elektrine.Repo.Migrations.AddExtendLayoutToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :extend_layout, :boolean, default: true, null: false
    end
  end
end
