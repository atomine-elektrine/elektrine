defmodule Elektrine.Repo.Migrations.AddContainerBackgroundToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :container_background_color, :string
      add :container_opacity, :float, default: 0.4
    end
  end
end
