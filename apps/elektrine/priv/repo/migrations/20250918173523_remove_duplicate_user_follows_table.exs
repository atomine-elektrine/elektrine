defmodule Elektrine.Repo.Migrations.RemoveDuplicateUserFollowsTable do
  use Ecto.Migration

  def change do
    # Remove the duplicate user_follows table since we're using the existing follows table
    drop table(:user_follows)
  end
end
