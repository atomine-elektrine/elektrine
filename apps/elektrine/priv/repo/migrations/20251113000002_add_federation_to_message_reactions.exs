defmodule Elektrine.Repo.Migrations.AddFederationToMessageReactions do
  use Ecto.Migration

  def change do
    alter table(:message_reactions) do
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)
      add :federated, :boolean, default: false
    end

    # Add index for querying federated reactions
    create index(:message_reactions, [:remote_actor_id])
    create index(:message_reactions, [:federated])

    # Add unique constraint for federated reactions (one emoji per remote actor per message)
    create unique_index(:message_reactions, [:message_id, :remote_actor_id, :emoji],
             name: :message_reactions_federated_unique_index,
             where: "remote_actor_id IS NOT NULL"
           )
  end
end
