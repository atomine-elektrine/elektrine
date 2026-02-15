defmodule Elektrine.Repo.Migrations.AddTickColorToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :tick_color, :string, default: "#1d9bf0"
    end
  end
end
