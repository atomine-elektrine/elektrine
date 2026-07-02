defmodule Elektrine.Repo.Migrations.CreateAccountSubscriptions do
  use Ecto.Migration

  def change do
    create table(:account_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :subscribed_user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(
             :account_subscriptions,
             :account_subscriptions_exactly_one_target,
             check:
               "(subscribed_user_id IS NOT NULL AND remote_actor_id IS NULL) OR (subscribed_user_id IS NULL AND remote_actor_id IS NOT NULL)"
           )

    create constraint(
             :account_subscriptions,
             :account_subscriptions_not_self,
             check: "subscribed_user_id IS NULL OR user_id <> subscribed_user_id"
           )

    create unique_index(:account_subscriptions, [:user_id, :subscribed_user_id],
             where: "subscribed_user_id IS NOT NULL",
             name: :account_subscriptions_user_local_unique_idx
           )

    create unique_index(:account_subscriptions, [:user_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL",
             name: :account_subscriptions_user_remote_unique_idx
           )
  end
end
