defmodule Elektrine.Repo.Migrations.CreateFederatedLikes do
  use Ecto.Migration

  def change do
    create table(:federated_likes) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :activitypub_id, :string

      timestamps()
    end

    create unique_index(:federated_likes, [:message_id, :remote_actor_id])
    create index(:federated_likes, [:remote_actor_id])
    create index(:federated_likes, [:activitypub_id])
  end
end
