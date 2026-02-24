defmodule Elektrine.Repo.Migrations.AddActivityPubActorTypeHotPathIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activitypub_actors_actor_type_id_idx
    ON activitypub_actors (actor_type, id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS activitypub_actors_actor_type_id_idx")
  end
end
