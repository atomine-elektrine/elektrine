defmodule Elektrine.Repo.Migrations.AddFederatedBoosts do
  use Ecto.Migration

  def change do
    create table(:federated_boosts) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :activitypub_id, :string

      timestamps()
    end

    create unique_index(:federated_boosts, [:message_id, :remote_actor_id])
    create index(:federated_boosts, [:remote_actor_id])
    create index(:federated_boosts, [:activitypub_id])
  end
end
