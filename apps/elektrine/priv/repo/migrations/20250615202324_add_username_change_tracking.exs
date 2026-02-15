defmodule Elektrine.Repo.Migrations.AddUsernameChangeTracking do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_username_change_at, :utc_datetime
    end
  end
end
