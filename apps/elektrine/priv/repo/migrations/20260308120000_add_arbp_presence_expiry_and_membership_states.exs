defmodule Elektrine.Repo.Migrations.AddArbpPresenceExpiryAndMembershipStates do
  use Ecto.Migration

  def change do
    alter table(:messaging_federation_presence_states) do
      add :expires_at_remote, :utc_datetime
    end

    create index(
             :messaging_federation_presence_states,
             [:expires_at_remote],
             name: :messaging_federation_presence_states_expires_at_idx
           )

    create table(:messaging_federation_membership_states) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :role, :string, null: false
      add :state, :string, null: false
      add :joined_at_remote, :utc_datetime
      add :updated_at_remote, :utc_datetime, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_membership_states,
             [:conversation_id, :remote_actor_id],
             name: :messaging_federation_membership_states_unique
           )

    create index(
             :messaging_federation_membership_states,
             [:remote_actor_id],
             name: :messaging_federation_membership_states_actor_idx
           )
  end
end
