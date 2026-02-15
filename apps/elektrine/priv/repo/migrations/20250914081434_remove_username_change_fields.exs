defmodule Elektrine.Repo.Migrations.RemoveUsernameChangeFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :last_username_change_at
    end
  end
end
