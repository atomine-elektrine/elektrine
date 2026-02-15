defmodule Elektrine.Repo.Migrations.AddVisibleToUserBadges do
  use Ecto.Migration

  def change do
    alter table(:user_badges) do
      add :visible, :boolean, default: true
    end
  end
end
