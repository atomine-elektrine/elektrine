defmodule Elektrine.Repo.Migrations.AddLastReadMessageIdToConversationMembers do
  use Ecto.Migration

  def change do
    alter table(:conversation_members) do
      add :last_read_message_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:conversation_members, [:last_read_message_id])
  end
end
