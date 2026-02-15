defmodule Elektrine.Repo.Migrations.CreateSigningKeys do
  use Ecto.Migration

  def change do
    create table(:signing_keys, primary_key: false) do
      # key_id is the primary key (e.g., "https://example.com/users/alice#main-key")
      add :key_id, :string, primary_key: true, null: false

      # Foreign keys - a key belongs to either a local user OR a remote actor
      add :user_id, references(:users, on_delete: :delete_all), null: true
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: true

      # Key material
      add :public_key, :text, null: false
      # Private key only for local users
      add :private_key, :text, null: true

      timestamps()
    end

    # Index for looking up keys by user
    create index(:signing_keys, [:user_id], where: "user_id IS NOT NULL")
    create index(:signing_keys, [:remote_actor_id], where: "remote_actor_id IS NOT NULL")

    # Ensure a key belongs to exactly one entity
    create constraint(:signing_keys, :must_have_owner,
             check:
               "(user_id IS NOT NULL AND remote_actor_id IS NULL) OR (user_id IS NULL AND remote_actor_id IS NOT NULL)"
           )
  end
end
