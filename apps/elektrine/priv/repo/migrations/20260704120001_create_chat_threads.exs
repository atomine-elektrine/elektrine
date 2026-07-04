defmodule Elektrine.Repo.Migrations.CreateChatThreads do
  use Ecto.Migration

  def change do
    create table(:chat_threads) do
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all), null: false
      add :root_message_id, references(:chat_messages, on_delete: :nilify_all)
      add :title, :string, null: false
      add :creator_id, references(:users, on_delete: :nilify_all)
      add :archived_at, :utc_datetime
      add :last_activity_at, :utc_datetime
      add :message_count, :integer, null: false, default: 0
      add :federation_id, :string
      add :origin_domain, :string

      timestamps(type: :utc_datetime)
    end

    create index(:chat_threads, [:conversation_id, :archived_at])
    create index(:chat_threads, [:creator_id])
    create unique_index(:chat_threads, [:root_message_id])

    # Remote threads are keyed by the id the origin domain assigned them.
    create unique_index(:chat_threads, [:federation_id, :origin_domain],
             where: "federation_id IS NOT NULL"
           )
  end
end
