defmodule Elektrine.Repo.Migrations.AddUniqueActorUsernameDomain do
  use Ecto.Migration

  def up do
    # First, find and merge duplicate actors (keep the oldest, update references)
    # This raw SQL handles the deduplication before adding the unique constraint

    execute """
    -- Update messages to reference the oldest actor for each username/domain pair
    UPDATE messages
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE messages.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update follows to reference the oldest actor
    UPDATE follows
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE follows.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update federated_boosts to reference the oldest actor
    UPDATE federated_boosts
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE federated_boosts.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update federated_dislikes to reference the oldest actor
    UPDATE federated_dislikes
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE federated_dislikes.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update message_reactions to reference the oldest actor
    UPDATE message_reactions
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE message_reactions.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update list_members to reference the oldest actor
    UPDATE list_members
    SET remote_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE list_members.remote_actor_id = dup.id AND dup.id != keeper.id;
    """

    execute """
    -- Update conversations to reference the oldest actor
    UPDATE conversations
    SET remote_group_actor_id = keeper.id
    FROM (
      SELECT username, domain, MIN(id) as id
      FROM activitypub_actors
      GROUP BY username, domain
    ) keeper
    JOIN activitypub_actors dup ON dup.username = keeper.username AND dup.domain = keeper.domain
    WHERE conversations.remote_group_actor_id = dup.id AND dup.id != keeper.id;
    """

    # Now delete the duplicate actors (keeping the oldest)
    execute """
    DELETE FROM activitypub_actors
    WHERE id NOT IN (
      SELECT MIN(id)
      FROM activitypub_actors
      GROUP BY username, domain
    );
    """

    # Drop the existing non-unique index first
    drop_if_exists index(:activitypub_actors, [:username, :domain],
                     name: :activitypub_actors_username_domain_index
                   )

    # Add unique constraint on username + domain
    create unique_index(:activitypub_actors, [:username, :domain],
             name: :activitypub_actors_username_domain_unique_index
           )
  end

  def down do
    drop_if_exists index(:activitypub_actors, [:username, :domain],
                     name: :activitypub_actors_username_domain_unique_index
                   )

    # Recreate the original non-unique index
    create_if_not_exists index(:activitypub_actors, [:username, :domain],
                           name: :activitypub_actors_username_domain_index
                         )
  end
end
