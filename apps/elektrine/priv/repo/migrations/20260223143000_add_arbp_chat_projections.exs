defmodule Elektrine.Repo.Migrations.AddArbpChatProjections do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_extension_events) do
      add :event_type, :string, null: false
      add :origin_domain, :string, null: false
      add :event_key, :string, null: false
      add :status, :string
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime

      add :server_id, references(:messaging_servers, on_delete: :delete_all)
      add :conversation_id, references(:conversations, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_extension_events,
             [:event_type, :origin_domain, :event_key],
             name: :messaging_federation_extension_events_unique
           )

    create index(
             :messaging_federation_extension_events,
             [:server_id, :event_type],
             name: :messaging_federation_extension_events_server_type_idx
           )

    create index(
             :messaging_federation_extension_events,
             [:conversation_id, :event_type],
             name: :messaging_federation_extension_events_conversation_type_idx
           )

    create index(
             :messaging_federation_extension_events,
             [:occurred_at],
             name: :messaging_federation_extension_events_occurred_at_idx
           )

    create table(:messaging_federation_read_receipts) do
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :read_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_read_receipts,
             [:chat_message_id, :remote_actor_id],
             name: :messaging_federation_read_receipts_unique
           )

    create index(
             :messaging_federation_read_receipts,
             [:chat_message_id, :read_at],
             name: :messaging_federation_read_receipts_message_read_at_idx
           )

    create index(
             :messaging_federation_read_receipts,
             [:remote_actor_id],
             name: :messaging_federation_read_receipts_actor_idx
           )

    create table(:messaging_federation_presence_states) do
      add :server_id, references(:messaging_servers, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :status, :string, null: false
      add :activities, :map, null: false, default: %{}
      add :updated_at_remote, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_presence_states,
             [:server_id, :remote_actor_id],
             name: :messaging_federation_presence_states_unique
           )

    create index(
             :messaging_federation_presence_states,
             [:server_id, :status],
             name: :messaging_federation_presence_states_server_status_idx
           )

    create index(
             :messaging_federation_presence_states,
             [:updated_at_remote],
             name: :messaging_federation_presence_states_updated_at_remote_idx
           )
  end
end
