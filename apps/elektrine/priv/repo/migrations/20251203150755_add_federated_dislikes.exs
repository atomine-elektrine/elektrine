defmodule Elektrine.Repo.Migrations.AddFederatedDislikes do
  use Ecto.Migration

  def change do
    # Add dislike_count column to messages table
    alter table(:messages) do
      add :dislike_count, :integer, default: 0
    end

    # Create federated_dislikes table
    create table(:federated_dislikes) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :activitypub_id, :string

      timestamps()
    end

    create unique_index(:federated_dislikes, [:message_id, :remote_actor_id])
    create index(:federated_dislikes, [:remote_actor_id])
    create index(:federated_dislikes, [:activitypub_id])
  end
end
