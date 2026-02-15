defmodule Elektrine.Repo.Migrations.AddCommunitySupportToActivitypub do
  use Ecto.Migration

  def up do
    # Add community support to ActivityPub actors
    alter table(:activitypub_actors) do
      add :community_id, references(:conversations, on_delete: :delete_all), null: true
      add :moderators_url, :string
    end

    # Add index for community lookups
    create index(:activitypub_actors, [:community_id])

    # Drop constraint if it exists, then recreate with Group support
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'actor_type_must_be_valid'
      ) THEN
        ALTER TABLE activitypub_actors DROP CONSTRAINT actor_type_must_be_valid;
      END IF;
    END $$;
    """

    # Create new constraint with Group support
    create constraint(:activitypub_actors, :actor_type_must_be_valid,
             check: "actor_type IN ('Person', 'Group', 'Organization', 'Service', 'Application')"
           )
  end

  def down do
    # Remove community support
    drop index(:activitypub_actors, [:community_id])

    alter table(:activitypub_actors) do
      remove :community_id
      remove :moderators_url
    end

    # Restore original constraint
    drop constraint(:activitypub_actors, :actor_type_must_be_valid)

    create constraint(:activitypub_actors, :actor_type_must_be_valid,
             check: "actor_type = 'Person'"
           )
  end
end
