defmodule Elektrine.Repo.Migrations.AddLocationToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :location, :string
    end
  end
end
