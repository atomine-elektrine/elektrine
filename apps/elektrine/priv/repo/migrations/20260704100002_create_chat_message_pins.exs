defmodule Elektrine.Repo.Migrations.CreateChatMessagePins do
  use Ecto.Migration

  def change do
    create table(:chat_message_pins) do
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all), null: false
      add :message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :pinned_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:chat_message_pins, [:message_id])
    create index(:chat_message_pins, [:conversation_id, :inserted_at])
    create index(:chat_message_pins, [:pinned_by_id])
  end
end
