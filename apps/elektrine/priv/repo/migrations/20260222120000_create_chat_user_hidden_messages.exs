defmodule Elektrine.Repo.Migrations.CreateChatUserHiddenMessages do
  use Ecto.Migration

  def change do
    create table(:chat_user_hidden_messages) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :hidden_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:chat_user_hidden_messages, [:user_id, :chat_message_id],
             name: :chat_user_hidden_messages_user_message_unique
           )

    create index(:chat_user_hidden_messages, [:user_id, :hidden_at])
    create index(:chat_user_hidden_messages, [:chat_message_id])
  end
end
