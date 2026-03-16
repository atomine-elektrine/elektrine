defmodule Elektrine.Repo.Migrations.CreateMessagingFederationRoomPresenceStates do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_room_presence_states) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :status, :string, null: false
      add :activities, :map, null: false, default: %{}
      add :updated_at_remote, :utc_datetime, null: false
      add :expires_at_remote, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_room_presence_states,
             [:conversation_id, :remote_actor_id],
             name: :messaging_federation_room_presence_states_unique
           )

    create index(
             :messaging_federation_room_presence_states,
             [:conversation_id, :expires_at_remote],
             name: :messaging_federation_room_presence_states_conversation_expires_at_idx
           )

    create index(
             :messaging_federation_room_presence_states,
             [:updated_at_remote],
             name: :messaging_federation_room_presence_states_updated_at_remote_idx
           )
  end
end
