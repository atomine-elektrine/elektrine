defmodule Elektrine.Repo.Migrations.AddActivitypubPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Index on activitypub_actors.domain for faster lookups by domain
    create_if_not_exists index(:activitypub_actors, [:domain])

    # Index on activitypub_actors.uri for faster lookups
    create_if_not_exists index(:activitypub_actors, [:uri])

    # Index on activitypub_actors.username for username lookups
    create_if_not_exists index(:activitypub_actors, [:username])

    # Composite index for username+domain lookups
    create_if_not_exists index(:activitypub_actors, [:username, :domain])

    # Index on messages.activitypub_id for faster federation lookups
    create_if_not_exists index(:messages, [:activitypub_id])

    # Index on messages.remote_actor_id for fetching posts by remote actor
    create_if_not_exists index(:messages, [:remote_actor_id])

    # GIN index on media_metadata for JSONB queries (community_actor_uri, inReplyTo, etc.)
    execute(
      "CREATE INDEX IF NOT EXISTS messages_media_metadata_gin_idx ON messages USING GIN (media_metadata jsonb_path_ops)",
      "DROP INDEX IF EXISTS messages_media_metadata_gin_idx"
    )

    # Expression index on community_actor_uri for faster community post lookups
    execute(
      "CREATE INDEX IF NOT EXISTS messages_community_actor_uri_idx ON messages ((media_metadata->>'community_actor_uri')) WHERE media_metadata->>'community_actor_uri' IS NOT NULL",
      "DROP INDEX IF EXISTS messages_community_actor_uri_idx"
    )

    # Index on follows.remote_actor_id for faster follower lookups
    create_if_not_exists index(:follows, [:remote_actor_id])

    # Index on follows for follower_id + remote_actor_id combinations
    create_if_not_exists index(:follows, [:follower_id, :remote_actor_id])
  end
end
