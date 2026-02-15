defmodule Elektrine.Repo.Migrations.AddFederatedSourceToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # ActivityPub Group URI (e.g., https://lemmy.ml/c/technology)
      add :federated_source, :string
      # Link to Group actor
      add :remote_group_actor_id, references(:activitypub_actors, on_delete: :nilify_all)
      # True if this mirrors a remote community
      add :is_federated_mirror, :boolean, default: false
    end

    # Index for looking up mirror communities by remote source
    create index(:conversations, [:federated_source])
    create index(:conversations, [:remote_group_actor_id])
    create index(:conversations, [:is_federated_mirror])
  end
end
