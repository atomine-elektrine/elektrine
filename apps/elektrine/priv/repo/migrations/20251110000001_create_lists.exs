defmodule Elektrine.Repo.Migrations.CreateLists do
  use Ecto.Migration

  def change do
    # Lists table for curated user collections
    create table(:lists) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      # "private" or "public"
      add :visibility, :string, default: "public", null: false

      timestamps()
    end

    create index(:lists, [:user_id])
    create unique_index(:lists, [:user_id, :name])

    # List members - can be local users or remote actors
    create table(:list_members) do
      add :list_id, references(:lists, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)

      timestamps()
    end

    create index(:list_members, [:list_id])
    create index(:list_members, [:user_id])
    create index(:list_members, [:remote_actor_id])

    # Ensure either user_id or remote_actor_id is set, but not both
    create constraint(:list_members, :user_or_remote_actor,
             check:
               "(user_id IS NOT NULL AND remote_actor_id IS NULL) OR (user_id IS NULL AND remote_actor_id IS NOT NULL)"
           )

    # Prevent duplicates in a list
    create unique_index(:list_members, [:list_id, :user_id], where: "user_id IS NOT NULL")

    create unique_index(:list_members, [:list_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL"
           )
  end
end
