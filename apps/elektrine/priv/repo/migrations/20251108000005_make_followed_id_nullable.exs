defmodule Elektrine.Repo.Migrations.MakeFollowedIdNullable do
  use Ecto.Migration

  def change do
    # Make followed_id nullable for local->remote follows
    alter table(:follows) do
      modify :followed_id, :integer, null: true
    end
  end
end
