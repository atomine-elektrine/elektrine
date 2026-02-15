defmodule Elektrine.Repo.Migrations.AddContainerPatternToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :container_pattern, :string, default: "none"
      add :pattern_color, :string
    end
  end
end
