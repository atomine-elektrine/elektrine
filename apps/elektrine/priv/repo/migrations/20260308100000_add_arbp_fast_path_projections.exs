defmodule Elektrine.Repo.Migrations.AddArbpFastPathProjections do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_read_cursors) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :read_at, :utc_datetime, null: false
      add :read_through_sequence, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_read_cursors,
             [:conversation_id, :remote_actor_id],
             name: :messaging_federation_read_cursors_unique
           )

    create index(
             :messaging_federation_read_cursors,
             [:conversation_id, :chat_message_id],
             name: :messaging_federation_read_cursors_conversation_message_idx
           )

    create index(
             :messaging_federation_read_cursors,
             [:remote_actor_id],
             name: :messaging_federation_read_cursors_actor_idx
           )
  end
end
