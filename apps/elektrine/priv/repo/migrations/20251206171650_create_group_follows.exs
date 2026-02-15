defmodule Elektrine.Repo.Migrations.CreateGroupFollows do
  use Ecto.Migration

  def change do
    create table(:group_follows) do
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :group_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :activitypub_id, :string
      add :pending, :boolean, default: false

      timestamps()
    end

    create unique_index(:group_follows, [:remote_actor_id, :group_actor_id])
    create index(:group_follows, [:group_actor_id])
    create index(:group_follows, [:activitypub_id])
  end
end
