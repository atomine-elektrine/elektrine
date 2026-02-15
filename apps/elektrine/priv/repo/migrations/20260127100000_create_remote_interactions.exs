defmodule Elektrine.Repo.Migrations.CreateRemoteInteractions do
  use Ecto.Migration

  def change do
    create table(:remote_interactions) do
      add(:interaction_type, :string, null: false)
      add(:actor_uri, :string, null: false)
      add(:emoji, :string)
      add(:message_id, references(:messages, on_delete: :delete_all), null: false)
      add(:remote_actor_id, references(:activitypub_actors, on_delete: :nilify_all))

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Index for querying interactions by message
    create(index(:remote_interactions, [:message_id, :interaction_type]))

    # Index for checking if an actor has interacted
    create(index(:remote_interactions, [:message_id, :actor_uri]))

    # Unique constraint to prevent duplicate interactions
    create(
      unique_index(:remote_interactions, [:message_id, :actor_uri, :interaction_type, :emoji],
        name: :remote_interactions_unique_index,
        nulls_distinct: true
      )
    )

    # Index for emoji reactions
    create(
      index(:remote_interactions, [:message_id, :emoji],
        where: "interaction_type = 'emoji_react'"
      )
    )
  end
end
