defmodule Elektrine.Repo.Migrations.MakeFollowerIdNullable do
  use Ecto.Migration

  def change do
    # Make follower_id and followed_id nullable to support remote follows
    # Remote follows use remote_actor_id in combination with one of these
    alter table(:follows) do
      modify :follower_id, :integer, null: true
      modify :followed_id, :integer, null: true
    end
  end
end
