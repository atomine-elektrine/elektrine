defmodule Elektrine.Repo.Migrations.AddPatternOpacityToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :pattern_opacity, :float, default: 0.2
    end
  end
end
