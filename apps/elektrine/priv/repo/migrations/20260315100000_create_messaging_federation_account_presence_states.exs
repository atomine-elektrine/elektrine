defmodule Elektrine.Repo.Migrations.CreateMessagingFederationAccountPresenceStates do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_account_presence_states) do
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :status, :string, null: false
      add :activities, :map, null: false, default: %{}
      add :updated_at_remote, :utc_datetime, null: false
      add :expires_at_remote, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_account_presence_states,
             [:remote_actor_id],
             name: :messaging_federation_account_presence_states_unique
           )

    create index(
             :messaging_federation_account_presence_states,
             [:expires_at_remote],
             name: :messaging_federation_account_presence_states_expires_at_idx
           )

    create index(
             :messaging_federation_account_presence_states,
             [:updated_at_remote],
             name: :messaging_federation_account_presence_states_updated_at_remote_idx
           )
  end
end
