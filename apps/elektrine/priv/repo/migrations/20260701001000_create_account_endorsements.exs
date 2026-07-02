defmodule Elektrine.Repo.Migrations.CreateAccountEndorsements do
  use Ecto.Migration

  def change do
    create table(:account_endorsements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endorsed_user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(
             :account_endorsements,
             :account_endorsements_exactly_one_target,
             check:
               "(endorsed_user_id IS NOT NULL AND remote_actor_id IS NULL) OR (endorsed_user_id IS NULL AND remote_actor_id IS NOT NULL)"
           )

    create constraint(
             :account_endorsements,
             :account_endorsements_not_self,
             check: "endorsed_user_id IS NULL OR user_id <> endorsed_user_id"
           )

    create unique_index(:account_endorsements, [:user_id, :endorsed_user_id],
             where: "endorsed_user_id IS NOT NULL",
             name: :account_endorsements_user_local_unique_idx
           )

    create unique_index(:account_endorsements, [:user_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL",
             name: :account_endorsements_user_remote_unique_idx
           )

    create index(:account_endorsements, [:user_id, :inserted_at])
  end
end
