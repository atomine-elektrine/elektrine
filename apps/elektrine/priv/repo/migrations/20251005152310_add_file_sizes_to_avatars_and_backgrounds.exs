defmodule Elektrine.Repo.Migrations.AddFileSizesToAvatarsAndBackgrounds do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :avatar_size, :integer, default: 0
    end

    alter table(:user_profiles) do
      add :avatar_size, :integer, default: 0
      add :banner_size, :integer, default: 0
      add :background_size, :integer, default: 0
    end
  end
end
