defmodule Elektrine.Repo.Migrations.DropOldUsernameIndex do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:users, [:username], name: :users_username_index)
  end
end
